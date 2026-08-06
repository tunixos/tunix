#include <stdint.h>

#include "include/klock.h"

static volatile uint32_t next_ticket;
static volatile uint32_t now_serving;

void kernel_lock(void) {
    uint32_t ticket = __atomic_fetch_add(&next_ticket, 1, __ATOMIC_RELAXED);
    while (__atomic_load_n(&now_serving, __ATOMIC_ACQUIRE) != ticket)
        __asm__ volatile("pause");
}

void kernel_unlock(void) {
    __atomic_store_n(&now_serving, now_serving + 1, __ATOMIC_RELEASE);
}
