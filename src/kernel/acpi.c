/*
 * Just enough ACPI to find the interrupt controllers.
 *
 * The 8259 PIC this kernel started on is a compatibility device. On real
 * hardware the interrupt a PCI card raises does not arrive on the line its
 * config space names -- the routing goes through an IOAPIC, and which of its
 * inputs a device lands on is something only the firmware's tables say. So
 * before anything can be routed, the MADT has to be read.
 *
 * Nothing here interprets AML or walks the device tree; the tables this reads
 * are plain arrays with checksums, and that is deliberately all it does.
 */
#include <stdint.h>
#include <stddef.h>

#include "include/acpi.h"
#include "include/vmm.h"
#include "include/kstring.h"

extern void kprintf(const char *fmt, ...);
extern uint64_t tunix_boot_rsdp(void);

#define RSDP_SIGNATURE "RSD PTR "
#define RSDP_SIGNATURE_BYTES 8U
#define RSDP_V1_BYTES 20U
#define RSDP_FULL_BYTES 36U
#define RSDP_REVISION_2 2U

#define SIGNATURE_BYTES 4U
#define MADT_SIGNATURE "APIC"

/* MADT entry types. Only the three that decide routing are read. */
#define MADT_LOCAL_APIC 0U
#define MADT_IO_APIC 1U
#define MADT_INTERRUPT_OVERRIDE 2U

#define MADT_HEADER_BYTES 44U
#define MADT_LOCAL_APIC_ADDRESS_OFFSET 36U

/* Polarity and trigger live in the same 16-bit flags word of an override. */
#define OVERRIDE_POLARITY_MASK 0x3U
#define OVERRIDE_POLARITY_LOW 3U
#define OVERRIDE_TRIGGER_SHIFT 2U
#define OVERRIDE_TRIGGER_MASK 0x3U
#define OVERRIDE_TRIGGER_LEVEL 3U

struct acpi_header {
    char signature[SIGNATURE_BYTES];
    uint32_t length;
    uint8_t revision;
    uint8_t checksum;
    char oem_id[6];
    char oem_table_id[8];
    uint32_t oem_revision;
    uint32_t creator_id;
    uint32_t creator_revision;
} __attribute__((packed));

static struct acpi_machine machine;
static int parsed;

/* The kernel's string helpers have no memcmp, and a table signature is the
   only thing here that needs one. */
static int signature_is(const void *table, const char *expected, unsigned length) {
    const uint8_t *bytes = table;
    for (unsigned i = 0; i < length; i++)
        if (bytes[i] != (uint8_t)expected[i]) return 0;
    return 1;
}

/* Every ACPI table is checksummed by its bytes summing to zero in eight bits,
   which is the only way to tell a table from whatever else is at that
   address on a machine whose firmware got the pointer wrong. */
static int checksum_ok(const void *table, uint32_t length) {
    const uint8_t *bytes = table;
    uint8_t total = 0;
    for (uint32_t i = 0; i < length; i++) total = (uint8_t)(total + bytes[i]);
    return total == 0;
}

/*
 * ACPI tables are not in the direct map and cannot be.
 *
 * Firmware puts them just under the top of low memory -- on a 2 GiB machine
 * that is around 0x7FFE0000, while the direct map stops at PMM_DIRECT_MAP_LIMIT
 * (1792 MiB). Handing such an address to vmm_phys_to_virt() panics, which is
 * the right answer to the question it was asked and the wrong one here. So
 * these get a window of their own, next to the one the xHCI registers use.
 */
#define ACPI_WINDOW_OFFSET 0x00100000ULL
#define ACPI_WINDOW_BYTES 0x00200000ULL
#define ACPI_PAGE_BYTES 4096ULL

static uint64_t window_used;

static const void *map_physical(uint64_t physical, uint32_t length) {
    if (!physical || !length) return NULL;
    uint64_t page = physical & ~(ACPI_PAGE_BYTES - 1);
    uint64_t offset = physical - page;
    uint64_t bytes = (offset + length + ACPI_PAGE_BYTES - 1) & ~(ACPI_PAGE_BYTES - 1);
    if (window_used + bytes > ACPI_WINDOW_BYTES) return NULL;

    uint64_t base = DEVICE_MMIO_VIRTUAL_BASE + ACPI_WINDOW_OFFSET + window_used;
    uint64_t cr3 = vmm_kernel_cr3();
    for (uint64_t i = 0; i < bytes; i += ACPI_PAGE_BYTES) {
        if (vmm_map_page_in(cr3, base + i, page + i,
                            PAGE_WRITE | PAGE_DEVICE | PAGE_NX) != 0) return NULL;
    }
    window_used += bytes;
    return (const void *)(base + offset);
}

/* A table states its own length, so it takes two goes: the header first, then
   the whole of it. The window is large enough to spend a page finding out. */
static const struct acpi_header *map_table(uint64_t physical) {
    const struct acpi_header *header = map_physical(physical, sizeof(*header));
    if (!header) return NULL;
    return map_physical(physical, header->length);
}

static void parse_madt(const struct acpi_header *madt) {
    const uint8_t *base = (const uint8_t *)madt;
    machine.local_apic = *(const uint32_t *)(base + MADT_LOCAL_APIC_ADDRESS_OFFSET);

    for (uint32_t offset = MADT_HEADER_BYTES; offset + 2U <= madt->length; ) {
        uint8_t type = base[offset];
        uint8_t length = base[offset + 1U];
        if (!length || offset + length > madt->length) break;
        const uint8_t *entry = base + offset;

        if (type == MADT_IO_APIC && machine.io_apic_count < ACPI_MAX_IO_APICS) {
            struct acpi_io_apic *io = &machine.io_apics[machine.io_apic_count++];
            io->id = entry[2];
            io->address = *(const uint32_t *)(entry + 4);
            io->global_base = *(const uint32_t *)(entry + 8);
        } else if (type == MADT_INTERRUPT_OVERRIDE &&
                   machine.override_count < ACPI_MAX_OVERRIDES) {
            struct acpi_override *over = &machine.overrides[machine.override_count++];
            over->source = entry[3];
            over->global = *(const uint32_t *)(entry + 4);
            uint16_t flags = *(const uint16_t *)(entry + 8);
            over->active_low = (flags & OVERRIDE_POLARITY_MASK) == OVERRIDE_POLARITY_LOW;
            over->level_triggered =
                ((flags >> OVERRIDE_TRIGGER_SHIFT) & OVERRIDE_TRIGGER_MASK) ==
                OVERRIDE_TRIGGER_LEVEL;
        } else if (type == MADT_LOCAL_APIC) {
            machine.cpu_count++;
        }
        offset += length;
    }
}

/* Walk the RSDT or XSDT looking for one table. Both are arrays of pointers to
   tables; the only difference is how wide the pointers are. */
static const struct acpi_header *find_table(uint64_t root_physical, int wide,
                                            const char *signature) {
    const struct acpi_header *root = map_table(root_physical);
    if (!root || !checksum_ok(root, root->length)) return NULL;

    uint32_t entry_bytes = wide ? 8U : 4U;
    uint32_t count = (root->length - (uint32_t)sizeof(*root)) / entry_bytes;
    const uint8_t *entries = (const uint8_t *)root + sizeof(*root);

    for (uint32_t i = 0; i < count; i++) {
        uint64_t physical = wide ? *(const uint64_t *)(entries + i * entry_bytes)
                                 : *(const uint32_t *)(entries + i * entry_bytes);
        const struct acpi_header *table = map_table(physical);
        if (!table) continue;
        if (!signature_is(table->signature, signature, SIGNATURE_BYTES)) continue;
        if (!checksum_ok(table, table->length)) continue;
        return table;
    }
    return NULL;
}

const struct acpi_machine *acpi_describe_machine(void) {
    if (parsed) return machine.local_apic ? &machine : NULL;
    parsed = 1;

    uint64_t rsdp_physical = tunix_boot_rsdp();
    if (!rsdp_physical) return NULL;
    const uint8_t *rsdp = map_physical(rsdp_physical, RSDP_FULL_BYTES);
    if (!rsdp || !signature_is(rsdp, RSDP_SIGNATURE, RSDP_SIGNATURE_BYTES)) return NULL;
    if (!checksum_ok(rsdp, RSDP_V1_BYTES)) return NULL;

    /* Revision 2 machines have both a 32-bit RSDT and a 64-bit XSDT, and the
       specification says to prefer the wide one where it exists. */
    uint8_t revision = rsdp[15];
    const struct acpi_header *madt = NULL;
    if (revision >= RSDP_REVISION_2) {
        uint64_t xsdt = *(const uint64_t *)(rsdp + 24);
        if (xsdt) madt = find_table(xsdt, 1, MADT_SIGNATURE);
    }
    if (!madt) {
        uint32_t rsdt = *(const uint32_t *)(rsdp + 16);
        if (rsdt) madt = find_table(rsdt, 0, MADT_SIGNATURE);
    }
    if (!madt) return NULL;

    parse_madt(madt);
    if (!machine.local_apic || !machine.io_apic_count) return NULL;

    kprintf("ACPI: %u cpu(s), local apic at %x, %u ioapic(s), %u override(s)\n",
            (unsigned)machine.cpu_count, (unsigned)machine.local_apic,
            (unsigned)machine.io_apic_count, (unsigned)machine.override_count);
    return &machine;
}
