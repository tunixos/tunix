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
#include "../include/vmm.h"
#include "../include/time.h"
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

/* Operational registers, at CAPLENGTH from the base. */
#define XHCI_USBCMD 0x00U
#define XHCI_USBSTS 0x04U
#define XHCI_PAGESIZE 0x08U
#define XHCI_CONFIG 0x38U

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

static struct xhci_controller controller;

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

    controller.present = 1;
    kprintf("XHCI: %x.%x, %u slots, %u ports, %u-byte contexts\n",
            (unsigned)(controller.version >> 8), (unsigned)(controller.version & 0xFF),
            (unsigned)controller.max_slots, (unsigned)controller.max_ports,
            (unsigned)controller.context_bytes);
    return 0;
}
