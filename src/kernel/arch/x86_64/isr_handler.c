#include <stdint.h>
#include "../../include/input.h"
#include "../../include/interrupt.h"
#include "../../include/pic.h"
#include "../../include/process.h"
#include "../../include/signal.h"
#include "../../include/timer.h"

extern void kprintf(const char *fmt, ...);
extern void panic(const char *msg);

const char *exception_messages[] = {
    "Division By Zero", "Debug", "Non Maskable Interrupt", "Breakpoint",
    "Into Detected Overflow", "Out of Bounds", "Invalid Opcode", "No Coprocessor",
    "Double Fault", "Coprocessor Segment Overrun", "Bad TSS", "Segment Not Present",
    "Stack Fault", "General Protection Fault", "Page Fault", "Unknown Interrupt",
    "Coprocessor Fault", "Alignment Check", "Machine Check", "SIMD Floating-Point",
    "Virtualization", "Control Protection", "Reserved", "Reserved",
    "Reserved", "Reserved", "Reserved", "Reserved",
    "Hypervisor Injection", "VMM Communication", "Security", "Reserved"
};

/* Vector to signal, following the usual Unix mapping. */
static int fault_signal(uint64_t vector) {
    switch (vector) {
        case 0:  return SIGFPE;   /* divide by zero */
        case 6:  return SIGILL;   /* invalid opcode */
        case 16:
        case 19: return SIGFPE;   /* x87 / SIMD floating point */
        case 17: return SIGBUS;   /* alignment check */
        default: return SIGSEGV;  /* page fault, GP fault, everything else */
    }
}

void isr_handler(struct interrupt_frame *regs) {
    if (regs->int_no == PIC_MASTER_VECTOR) {
        timer_irq(regs);
        pic_send_eoi((unsigned)regs->int_no);
        return;
    }
    if (regs->int_no == PIC_MASTER_VECTOR + 1U ||
        regs->int_no == PIC_SLAVE_VECTOR + 4U) {
        input_irq();
        pic_send_eoi((unsigned)regs->int_no);
        return;
    }
    if (regs->int_no < 32) {
        /* Capture before handling: terminating the faulting process switches
           context and overwrites regs with the next process's state, so
           reading afterwards would report the wrong RIP. */
        uint64_t fault_rip = regs->rip;
        uint64_t fault_error = regs->err_code;
        uint64_t fault_address = 0;
        if (regs->int_no == 14) /* page fault: CR2 holds the bad address */
            __asm__ volatile("mov %%cr2, %0" : "=r"(fault_address));

        /* A not-present write inside the stack window is the stack growing,
           not a crash. Bit 0 of the error code clear means the page is absent;
           a protection fault on a mapped page must never be papered over. */
        if (regs->int_no == 14 && (regs->cs & 3U) == 3U &&
            !(regs->err_code & 1U) && process_grow_user_stack(fault_address)) {
            return; /* page mapped; retry the faulting instruction */
        }

        if (process_fault_from_interrupt(regs, fault_signal(regs->int_no))) {
            kprintf("%s in user mode at RIP %p addr %p (error %x), signalling process\n",
                    exception_messages[regs->int_no], (void *)fault_rip,
                    (void *)fault_address, fault_error);
            return;
        }
        kprintf("Exception: %s\n", exception_messages[regs->int_no]);
        kprintf("Error Code: %x\n", regs->err_code);
        kprintf("RIP: %p\n", (void*)regs->rip);
        panic(exception_messages[regs->int_no]);
    }
    kprintf("Received interrupt: %d\n", regs->int_no);
}
