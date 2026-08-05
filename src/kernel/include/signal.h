#ifndef TUNIX_SIGNAL_H
#define TUNIX_SIGNAL_H

#include <stdint.h>

#define TUNIX_NSIG 32
#define SIG_DFL 0ULL
#define SIG_IGN 1ULL

#define SIGHUP   1
#define SIGINT   2
#define SIGQUIT  3
#define SIGILL   4
#define SIGBUS   7
#define SIGFPE   8
#define SIGKILL  9
#define SIGUSR1 10
#define SIGSEGV 11
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define SIGCHLD 17
#define SIGCONT 18
#define SIGSTOP 19
#define SIGTSTP 20
#define SIGTTIN 21
#define SIGTTOU 22

#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2

#define SA_SIGINFO 0x00000004ULL
#define SA_ONSTACK 0x08000000ULL
#define SA_RESTART 0x10000000ULL

/* si_code: who raised the signal. Everything above zero means the kernel did. */
#define SI_USER   0
#define SI_KERNEL 0x80

/* What a SA_SIGINFO handler is handed: Linux's siginfo_t, and a context that
   is only ever read as a pointer here. */
#define SIGNAL_SIGINFO_SIZE 128
#define SIGNAL_CONTEXT_SIZE 1024

#define SS_ONSTACK 1
#define SS_DISABLE 2
#define MINSIGSTKSZ 2048ULL

struct tunix_sigaction {
    uint64_t handler;
    uint64_t flags;
    uint64_t restorer;
    uint64_t mask;
};

#endif
