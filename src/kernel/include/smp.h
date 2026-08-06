#ifndef TUNIX_SMP_H
#define TUNIX_SMP_H

#include <stdint.h>

/* The vectors the processors use to reach each other and themselves. High, so
   they cannot collide with a device line the IOAPIC might route. */
#define SMP_TIMER_VECTOR 0xF0U
#define SMP_INVALIDATE_VECTOR 0xF1U

/* Start every processor the firmware listed. Safe to call on a machine with
   one: it says so and returns. Must run after the APIC, the timer and the
   syscall entry are set up, and before the first process starts. */
void smp_init(void);
/* How many are running, the first one included. */
unsigned smp_cpu_count(void);

#endif
