#ifndef TUNIX_APIC_H
#define TUNIX_APIC_H

/* Enable the local APIC, mask the 8259 pair, and take over delivery. Returns
   -1 on a machine whose tables do not describe an IOAPIC, where the caller
   should stay on the PIC. */
int apic_init(void);

/* True once delivery has moved, which decides where an interrupt is
   acknowledged. */
int apic_is_active(void);
void apic_send_eoi(void);

/* Route one of the sixteen lines the PIC used to own, following whatever the
   firmware's overrides say about where it really arrives and how it is wired. */
int apic_route_legacy_irq(unsigned irq);

/* The same, for a line whose global number is already known -- a PCI device
   reading its own routing, once there is anything that does. */
int apic_route_irq(unsigned global, unsigned vector, int active_low,
                   int level_triggered);

#endif
