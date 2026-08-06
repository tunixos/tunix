#ifndef TUNIX_ACPI_H
#define TUNIX_ACPI_H

#include <stdint.h>

/* One machine has one IOAPIC in every configuration this kernel will meet; the
   room for more is because the table is allowed to list them and dropping the
   extras silently would be a lie. */
#define ACPI_MAX_IO_APICS 4U
#define ACPI_MAX_OVERRIDES 16U
/* The MADT may list more; the extras are counted and dropped, and the count is
   what /proc/cpuinfo reports, so an over-long table is visible rather than
   silently rounded down. */
#define ACPI_MAX_CPUS 32U

struct acpi_io_apic {
    uint8_t id;
    uint32_t address;
    /* The first global interrupt number this controller's inputs answer to. */
    uint32_t global_base;
};

/* The firmware saying "the legacy line you know as `source` is really wired to
   global interrupt `global`, and it is not active-high edge-triggered like the
   PIC's were". IRQ 0 arriving on global 2 is the usual one. */
struct acpi_override {
    uint8_t source;
    uint32_t global;
    uint8_t active_low;
    uint8_t level_triggered;
};

/* One processor the firmware says exists. `apic_id` is what an INIT/SIPI pair
   is addressed to, and it is not the index: firmware is free to number the
   processors however it likes, and on a machine with hyperthreading disabled
   in the BIOS the ids that remain are not contiguous. */
struct acpi_cpu {
    uint8_t acpi_id;
    uint8_t apic_id;
    uint8_t usable;
};

struct acpi_machine {
    uint32_t local_apic;
    uint32_t cpu_count;
    uint32_t cpu_listed;
    struct acpi_cpu cpus[ACPI_MAX_CPUS];
    uint32_t io_apic_count;
    struct acpi_io_apic io_apics[ACPI_MAX_IO_APICS];
    uint32_t override_count;
    struct acpi_override overrides[ACPI_MAX_OVERRIDES];
};

/* Parsed once and remembered. NULL when the machine has no usable tables, in
   which case the caller should stay on the 8259 pair. */
const struct acpi_machine *acpi_describe_machine(void);

#endif
