/*
 * xHCI: the USB host controller every machine built this decade has, and the
 * only way to reach a keyboard on one that has no PS/2 port left.
 *
 * This is the bring-up half -- find the controller, map its registers, reset
 * it and start it. What runs on top of it (rings, devices, HID) is layered
 * above and depends on nothing here beyond the register accessors.
 *
 * Two things about xHCI shape the code. Its registers live in four separate
 * blocks whose offsets are read out of the first one, so nothing can be a
 * fixed address; and the controller answers "not ready" for a while after a
 * reset, which is a state to wait out rather than an error.
 */
#include <stdint.h>
#include <stddef.h>

#include "../include/pci.h"
#include "../include/pmm.h"
#include "../include/vmm.h"
#include "../include/time.h"
#include "../include/kstring.h"
#include "../include/xhci.h"

extern void kprintf(const char *fmt, ...);

/* PCI class 0x0C.03.30 is "serial bus / USB / xHCI". The programming
   interface matters: the same class and subclass also cover UHCI, OHCI and
   EHCI, which share nothing with this. */
#define PCI_CLASS_SERIAL_BUS 0x0CU
#define PCI_SUBCLASS_USB 0x03U
#define PCI_PROG_IF_XHCI 0x30U

#define PCI_BAR_TYPE_MASK 0x6U
#define PCI_BAR_TYPE_64BIT 0x4U
#define PCI_BAR_IO 0x1U
#define PCI_BAR_ADDRESS_MASK 0xFFFFFFF0U
#define PCI_BAR0_OFFSET 0x10U

/* Capability registers, at the start of the mapping. */
/* CAPLENGTH is a byte and HCIVERSION the halfword above it, so both come out
   of one aligned dword: a 32-bit read at 0x02 would straddle into HCSPARAMS1
   and hand back a plausible-looking version that is really a slot count. */
#define XHCI_CAPLENGTH 0x00U
#define XHCI_VERSION_SHIFT 16U
#define XHCI_HCSPARAMS1 0x04U
#define XHCI_HCSPARAMS2 0x08U
#define XHCI_HCCPARAMS1 0x10U
#define XHCI_DBOFF 0x14U
#define XHCI_RTSOFF 0x18U

#define HCSPARAMS1_MAX_SLOTS_SHIFT 0U
#define HCSPARAMS1_MAX_SLOTS_MASK 0xFFU
#define HCSPARAMS1_MAX_PORTS_SHIFT 24U
#define HCSPARAMS1_MAX_PORTS_MASK 0xFFU
#define HCCPARAMS1_CONTEXT_64 (1U << 2)

#define HCSPARAMS2_SCRATCHPAD_HIGH_SHIFT 21U
#define HCSPARAMS2_SCRATCHPAD_HIGH_MASK 0x1FU
#define HCSPARAMS2_SCRATCHPAD_LOW_SHIFT 27U
#define HCSPARAMS2_SCRATCHPAD_LOW_MASK 0x1FU

/* Operational registers, at CAPLENGTH from the base. */
#define XHCI_USBCMD 0x00U
#define XHCI_USBSTS 0x04U
#define XHCI_PAGESIZE 0x08U
#define XHCI_CRCR 0x18U
#define XHCI_DCBAAP 0x30U
#define XHCI_CONFIG 0x38U

/* Interrupter 0, the only one this driver uses, at RTSOFF + 0x20. */
#define XHCI_INTERRUPTER0 0x20U
#define XHCI_IMAN 0x00U
#define XHCI_IMOD 0x04U
#define XHCI_ERSTSZ 0x08U
#define XHCI_ERSTBA 0x10U
#define XHCI_ERDP 0x18U

#define CRCR_RING_CYCLE_STATE (1ULL << 0)
/* Written back with the dequeue pointer to say the handler is done. */
#define ERDP_EVENT_HANDLER_BUSY (1ULL << 3)

/* A TRB is four dwords. The type lives in the top of the last one, and the
   bottom bit of that dword is the cycle bit -- the only thing that
   distinguishes an entry the controller has written from one left over from
   the ring's previous lap. */
#define TRB_BYTES 16U
#define TRB_TYPE_SHIFT 10U
#define TRB_TYPE_MASK 0x3FU
#define TRB_CYCLE (1U << 0)
#define TRB_TOGGLE_CYCLE (1U << 1)

#define TRB_TYPE_LINK 6U
#define TRB_TYPE_NO_OP_COMMAND 23U
#define TRB_TYPE_COMMAND_COMPLETION 33U
#define TRB_TYPE_PORT_STATUS_CHANGE 34U

#define TRB_COMPLETION_SHIFT 24U
#define TRB_COMPLETION_MASK 0xFFU
#define TRB_COMPLETION_SUCCESS 1U

/* One page each: 256 TRBs is far more than this driver ever has outstanding,
   and a page is the smallest thing the physical allocator hands out anyway. */
#define RING_BYTES 4096U
#define RING_TRB_COUNT (RING_BYTES / TRB_BYTES)
#define EVENT_RING_SEGMENTS 1U
#define ERST_ENTRY_BYTES 16U

#define COMMAND_TIMEOUT_NS (1000ULL * 1000ULL * 1000ULL)
#define RUN_TIMEOUT_NS (1000ULL * 1000ULL * 1000ULL)

#define USBCMD_RUN (1U << 0)
#define USBCMD_RESET (1U << 1)
#define USBSTS_HALTED (1U << 0)
#define USBSTS_HOST_ERROR (1U << 2)
#define USBSTS_NOT_READY (1U << 11)

/* The specification's own limits: 20 ms for a reset to complete, and the
   controller may hold "not ready" for a while after that. */
#define XHCI_RESET_TIMEOUT_NS (1000ULL * 1000ULL * 1000ULL)
#define XHCI_HALT_TIMEOUT_NS (100ULL * 1000ULL * 1000ULL)

#define MMIO_PAGE_BYTES 4096ULL
/* Enough for the capability, operational, runtime and doorbell blocks of any
   controller: the doorbell array is one dword per slot, the runtime block one
   interrupter set per interrupter, and both are bounded by the slot count. */
#define XHCI_REGISTER_BYTES 0x10000ULL

struct trb {
    uint32_t parameter_low;
    uint32_t parameter_high;
    uint32_t status;
    uint32_t control;
};

/* A producer ring the driver writes and the controller reads. The cycle bit
   is what says "this entry is mine now"; it flips every lap, so the ring never
   needs clearing and the controller never mistakes a stale entry for a new
   one. The last slot is always a Link back to the start. */
struct producer_ring {
    struct trb *entries;
    uint64_t physical;
    uint32_t index;
    uint32_t cycle;
};

/* The ring the controller writes and the driver reads. No link entry: it
   wraps, and the driver flips its own idea of the cycle bit when it does. */
struct event_ring {
    struct trb *entries;
    uint64_t physical;
    uint32_t index;
    uint32_t cycle;
};

static struct xhci_controller controller;
static struct producer_ring command_ring;
static struct event_ring event_ring;
static uint64_t *device_contexts;      /* the DCBAA */
static uint64_t interrupter;           /* runtime + XHCI_INTERRUPTER0 */

/* One zeroed page of DMA memory, with its physical address. The physical
   allocator only ever hands out memory inside the direct map, so a kernel
   pointer to it is a subtraction away and no extra mapping is needed. */
static void *dma_page(uint64_t *physical_out) {
    void *physical = pmm_alloc_page();
    if (!physical) return NULL;
    void *virtual_address = vmm_phys_to_virt((uint64_t)physical);
    if (!virtual_address) return NULL;
    memset(virtual_address, 0, RING_BYTES);
    *physical_out = (uint64_t)physical;
    return virtual_address;
}

static inline uint32_t mmio_read32(uint64_t address) {
    return *(volatile uint32_t *)address;
}

static inline void mmio_write32(uint64_t address, uint32_t value) {
    *(volatile uint32_t *)address = value;
}

uint32_t xhci_read32(uint64_t address) { return mmio_read32(address); }
void xhci_write32(uint64_t address, uint32_t value) { mmio_write32(address, value); }

uint64_t xhci_read64(uint64_t address) {
    /* Two 32-bit halves rather than one 64-bit access: a controller behind a
       32-bit bridge answers the wide read with garbage in the high word. */
    uint64_t low = mmio_read32(address);
    uint64_t high = mmio_read32(address + 4U);
    return low | (high << 32);
}

void xhci_write64(uint64_t address, uint64_t value) {
    mmio_write32(address, (uint32_t)value);
    mmio_write32(address + 4U, (uint32_t)(value >> 32));
}

struct xhci_controller *xhci_get(void) {
    return controller.present ? &controller : NULL;
}

/* Map the register block uncached. Returns the virtual base, or 0. */
static uint64_t map_registers(uint64_t physical) {
    if (physical & (MMIO_PAGE_BYTES - 1)) return 0;
    if (XHCI_REGISTER_BYTES > DEVICE_MMIO_VIRTUAL_BYTES) return 0;

    uint64_t cr3 = vmm_kernel_cr3();
    for (uint64_t offset = 0; offset < XHCI_REGISTER_BYTES; offset += MMIO_PAGE_BYTES) {
        if (vmm_map_page_in(cr3, DEVICE_MMIO_VIRTUAL_BASE + offset, physical + offset,
                            PAGE_WRITE | PAGE_DEVICE | PAGE_UNCACHED | PAGE_NX) != 0)
            return 0;
    }
    return DEVICE_MMIO_VIRTUAL_BASE;
}

/* Spin until the masked bits reach `wanted`, or the deadline passes. */
static int wait_for(uint64_t address, uint32_t mask, uint32_t wanted, uint64_t timeout_ns) {
    uint64_t deadline = time_uptime_ns() + timeout_ns;
    for (;;) {
        if ((mmio_read32(address) & mask) == wanted) return 0;
        if (time_uptime_ns() >= deadline) return -1;
        __asm__ volatile("pause");
    }
}

/* Stop the controller and put it back to its power-on state. Whatever the
   firmware left running -- and firmware does leave USB running, because it was
   reading a keyboard a moment ago -- is not a state this driver knows. */
static int reset_controller(void) {
    uint64_t operational = controller.operational;

    uint32_t command = mmio_read32(operational + XHCI_USBCMD);
    if (command & USBCMD_RUN) {
        mmio_write32(operational + XHCI_USBCMD, command & ~USBCMD_RUN);
        if (wait_for(operational + XHCI_USBSTS, USBSTS_HALTED, USBSTS_HALTED,
                     XHCI_HALT_TIMEOUT_NS) != 0) {
            kprintf("XHCI: controller will not halt\n");
            return -1;
        }
    }

    mmio_write32(operational + XHCI_USBCMD,
                 mmio_read32(operational + XHCI_USBCMD) | USBCMD_RESET);
    /* The reset bit clears itself when the reset is done, and only then is the
       rest of the register file worth reading. */
    if (wait_for(operational + XHCI_USBCMD, USBCMD_RESET, 0, XHCI_RESET_TIMEOUT_NS) != 0) {
        kprintf("XHCI: reset did not complete\n");
        return -1;
    }
    if (wait_for(operational + XHCI_USBSTS, USBSTS_NOT_READY, 0, XHCI_RESET_TIMEOUT_NS) != 0) {
        kprintf("XHCI: controller stayed not-ready after reset\n");
        return -1;
    }
    return 0;
}

/* Build a command ring: empty, with its last entry pointing back at the
   first. The Toggle Cycle bit on that link is what tells the controller to
   invert its cycle state on the way round, which is how a ring with no end
   marker still has laps. */
static int build_command_ring(void) {
    command_ring.entries = dma_page(&command_ring.physical);
    if (!command_ring.entries) return -1;
    command_ring.index = 0;
    command_ring.cycle = 1;

    struct trb *link = &command_ring.entries[RING_TRB_COUNT - 1];
    link->parameter_low = (uint32_t)command_ring.physical;
    link->parameter_high = (uint32_t)(command_ring.physical >> 32);
    link->status = 0;
    link->control = (TRB_TYPE_LINK << TRB_TYPE_SHIFT) | TRB_TOGGLE_CYCLE;

    xhci_write64(controller.operational + XHCI_CRCR,
                 command_ring.physical | CRCR_RING_CYCLE_STATE);
    return 0;
}

/* The event ring is described to the controller indirectly, through a table of
   segments; this driver uses exactly one segment, so the table has one entry. */
static int build_event_ring(void) {
    event_ring.entries = dma_page(&event_ring.physical);
    if (!event_ring.entries) return -1;
    event_ring.index = 0;
    event_ring.cycle = 1;

    uint64_t table_physical = 0;
    uint32_t *table = dma_page(&table_physical);
    if (!table) return -1;
    table[0] = (uint32_t)event_ring.physical;
    table[1] = (uint32_t)(event_ring.physical >> 32);
    table[2] = RING_TRB_COUNT;
    table[3] = 0;

    /* Size before base: the controller reads the table when the base is
       written, and a table it thinks is zero-length is one it never reads. */
    xhci_write32(interrupter + XHCI_ERSTSZ, EVENT_RING_SEGMENTS);
    xhci_write64(interrupter + XHCI_ERDP, event_ring.physical | ERDP_EVENT_HANDLER_BUSY);
    xhci_write64(interrupter + XHCI_ERSTBA, table_physical);
    return 0;
}

/* Slot contexts live in an array the controller owns; entry zero is reserved
   for the scratchpad table, which is memory the controller asks to borrow. */
static int build_device_contexts(void) {
    uint64_t physical = 0;
    device_contexts = dma_page(&physical);
    if (!device_contexts) return -1;

    uint32_t structural2 = xhci_read32(controller.base + XHCI_HCSPARAMS2);
    uint32_t scratchpads =
        ((structural2 >> HCSPARAMS2_SCRATCHPAD_HIGH_SHIFT) & HCSPARAMS2_SCRATCHPAD_HIGH_MASK) |
        (((structural2 >> HCSPARAMS2_SCRATCHPAD_LOW_SHIFT) & HCSPARAMS2_SCRATCHPAD_LOW_MASK) << 5);

    if (scratchpads) {
        uint64_t table_physical = 0;
        uint64_t *table = dma_page(&table_physical);
        if (!table) return -1;
        if (scratchpads > RING_BYTES / sizeof(uint64_t)) return -1;
        for (uint32_t i = 0; i < scratchpads; i++) {
            uint64_t buffer = 0;
            if (!dma_page(&buffer)) return -1;
            table[i] = buffer;
        }
        device_contexts[0] = table_physical;
    }

    xhci_write32(controller.operational + XHCI_CONFIG, controller.max_slots);
    xhci_write64(controller.operational + XHCI_DCBAAP, physical);
    return 0;
}

/* Put a TRB on the command ring and ring the controller's doorbell. */
static void submit_command(uint32_t type, uint64_t parameter) {
    struct trb *entry = &command_ring.entries[command_ring.index];
    entry->parameter_low = (uint32_t)parameter;
    entry->parameter_high = (uint32_t)(parameter >> 32);
    entry->status = 0;
    /* The cycle bit last: until it is written the controller must not see the
       entry, and everything above has to be in memory before it does. */
    __asm__ volatile("" ::: "memory");
    entry->control = (type << TRB_TYPE_SHIFT) | command_ring.cycle;

    command_ring.index++;
    if (command_ring.index == RING_TRB_COUNT - 1) {
        struct trb *link = &command_ring.entries[RING_TRB_COUNT - 1];
        link->control = (link->control & ~TRB_CYCLE) | command_ring.cycle;
        command_ring.index = 0;
        command_ring.cycle ^= 1;
    }

    __asm__ volatile("" ::: "memory");
    xhci_write32(controller.doorbell, 0);
}

/* Take the next event the controller has posted, or nothing. */
static int next_event(struct trb *out) {
    struct trb *entry = &event_ring.entries[event_ring.index];
    if ((entry->control & TRB_CYCLE) != event_ring.cycle) return 0;

    *out = *entry;
    event_ring.index++;
    if (event_ring.index == RING_TRB_COUNT) {
        event_ring.index = 0;
        event_ring.cycle ^= 1;
    }
    xhci_write64(interrupter + XHCI_ERDP,
                 (event_ring.physical + (uint64_t)event_ring.index * TRB_BYTES) |
                 ERDP_EVENT_HANDLER_BUSY);
    return 1;
}

/* Wait for the completion of the command just submitted. Port status changes
   arrive on the same ring and are simply stepped over here; enumeration reads
   the ports directly rather than relying on having caught the event. */
static int wait_for_command(uint32_t *completion_code) {
    uint64_t deadline = time_uptime_ns() + COMMAND_TIMEOUT_NS;
    for (;;) {
        struct trb event;
        if (next_event(&event)) {
            uint32_t type = (event.control >> TRB_TYPE_SHIFT) & TRB_TYPE_MASK;
            if (type == TRB_TYPE_COMMAND_COMPLETION) {
                *completion_code = (event.status >> TRB_COMPLETION_SHIFT) & TRB_COMPLETION_MASK;
                return 0;
            }
            if (type == TRB_TYPE_PORT_STATUS_CHANGE) continue;
        }
        if (time_uptime_ns() >= deadline) return -1;
        __asm__ volatile("pause");
    }
}

/* Start the controller and prove the rings work, which a No-Op command does
   exactly: it asks the controller for nothing except an answer. */
static int start_controller(void) {
    xhci_write32(controller.operational + XHCI_USBCMD,
                 xhci_read32(controller.operational + XHCI_USBCMD) | USBCMD_RUN);
    if (wait_for(controller.operational + XHCI_USBSTS, USBSTS_HALTED, 0, RUN_TIMEOUT_NS) != 0) {
        kprintf("XHCI: controller will not run\n");
        return -1;
    }

    submit_command(TRB_TYPE_NO_OP_COMMAND, 0);
    uint32_t completion = 0;
    if (wait_for_command(&completion) != 0) {
        kprintf("XHCI: no answer to the no-op command\n");
        return -1;
    }
    if (completion != TRB_COMPLETION_SUCCESS) {
        kprintf("XHCI: no-op command failed with code %u\n", (unsigned)completion);
        return -1;
    }
    return 0;
}

int xhci_init(void) {
    struct pci_device device;
    if (pci_find_class(PCI_CLASS_SERIAL_BUS, PCI_SUBCLASS_USB, &device) != 0) return -1;
    if (device.prog_if != PCI_PROG_IF_XHCI) {
        kprintf("XHCI: the USB controller is not xHCI (prog-if %x)\n", device.prog_if);
        return -1;
    }

    /* BAR0 is memory-mapped and, on every real xHCI, 64-bit -- which means it
       is a pair of BARs and the high half lives in BAR1. */
    if (device.bar[0] & PCI_BAR_IO) return -1;
    uint64_t physical = device.bar[0] & PCI_BAR_ADDRESS_MASK;
    if ((device.bar[0] & PCI_BAR_TYPE_MASK) == PCI_BAR_TYPE_64BIT)
        physical |= (uint64_t)device.bar[1] << 32;
    if (!physical) return -1;

    controller.base = map_registers(physical);
    if (!controller.base) {
        kprintf("XHCI: could not map registers at %x\n", (unsigned)physical);
        return -1;
    }

    /* Bus mastering off means every ring this driver builds is invisible to
       the controller, and nothing fails loudly -- it just never answers. */
    pci_enable_bus_mastering(&device);

    uint32_t length_and_version = mmio_read32(controller.base + XHCI_CAPLENGTH);
    uint8_t capability_length = (uint8_t)length_and_version;
    uint32_t structural = mmio_read32(controller.base + XHCI_HCSPARAMS1);
    uint32_t capabilities = mmio_read32(controller.base + XHCI_HCCPARAMS1);

    controller.operational = controller.base + capability_length;
    controller.runtime = controller.base + (mmio_read32(controller.base + XHCI_RTSOFF) & ~0x1FU);
    controller.doorbell = controller.base + (mmio_read32(controller.base + XHCI_DBOFF) & ~0x3U);
    controller.max_slots = (structural >> HCSPARAMS1_MAX_SLOTS_SHIFT) & HCSPARAMS1_MAX_SLOTS_MASK;
    controller.max_ports = (structural >> HCSPARAMS1_MAX_PORTS_SHIFT) & HCSPARAMS1_MAX_PORTS_MASK;
    controller.context_bytes = (capabilities & HCCPARAMS1_CONTEXT_64) ? 64U : 32U;
    controller.version = (uint16_t)(length_and_version >> XHCI_VERSION_SHIFT);

    if (!controller.max_slots || !controller.max_ports) {
        kprintf("XHCI: controller reports no slots or no ports\n");
        return -1;
    }

    if (reset_controller() != 0) return -1;

    interrupter = controller.runtime + XHCI_INTERRUPTER0;
    if (build_device_contexts() != 0 || build_command_ring() != 0 ||
        build_event_ring() != 0) {
        kprintf("XHCI: could not build the controller's rings\n");
        return -1;
    }
    if (start_controller() != 0) return -1;

    controller.present = 1;
    kprintf("XHCI: %x.%x, %u slots, %u ports, %u-byte contexts, rings answering\n",
            (unsigned)(controller.version >> 8), (unsigned)(controller.version & 0xFF),
            (unsigned)controller.max_slots, (unsigned)controller.max_ports,
            (unsigned)controller.context_bytes);
    return 0;
}
