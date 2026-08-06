#ifndef TUNIX_KLOCK_H
#define TUNIX_KLOCK_H

/*
 * One lock, held for the whole time a processor is inside the kernel.
 *
 * Nothing in this kernel was written to be entered twice at once: the process
 * queue is a bare linked list, the VFS tree has no locks, the page tables are
 * edited in place. Making each of those safe separately is a long job with a
 * long tail of races that only appear under load, and none of it is needed to
 * get work onto more than one processor -- user code is where the time goes,
 * and user code does not hold this.
 *
 * So the rule is the simple one: take it on the way in, drop it on the way
 * out, and let the processors run in parallel everywhere else. Kernel mode
 * runs with interrupts off, so a processor holding this can never be
 * interrupted into wanting it again, and the wait is always finite.
 *
 * It is a ticket lock rather than a test-and-set so that a processor entering
 * the kernel in a tight syscall loop cannot starve one that has been waiting.
 */
void kernel_lock(void);
void kernel_unlock(void);

#endif
