/*
 * signalfd-test -- signal delivery as a pollable descriptor.
 *
 * This mirrors what wl_event_loop_add_signal() does, because that is the reason
 * signalfd exists on Tunix at all:
 *
 *     sigemptyset(&mask); sigaddset(&mask, SIGUSR1);
 *     sigprocmask(SIG_BLOCK, &mask, NULL);
 *     fd = signalfd(-1, &mask, SFD_CLOEXEC);
 *     ... fold fd into the event loop, read struct signalfd_siginfo ...
 *
 * The blocking step is not optional: without it the ordinary delivery path
 * consumes the signal first and the descriptor never becomes readable.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <unistd.h>

static int failures;

static void check(int condition, const char *what) {
    if (condition) {
        printf("signalfd-test: ok   %s\n", what);
    } else {
        printf("signalfd-test: FAIL %s (errno=%d %s)\n", what, errno, strerror(errno));
        failures++;
    }
}

int main(void) {
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGUSR1);
    sigaddset(&mask, SIGUSR2);

    check(sigprocmask(SIG_BLOCK, &mask, NULL) == 0, "block the watched signals");

    int fd = signalfd(-1, &mask, SFD_CLOEXEC);
    check(fd >= 0, "signalfd(-1, ...) creates a descriptor");
    if (fd < 0) return 1;

    /* Nothing pending yet, so an event loop must not see it as readable. */
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    check(poll(&pfd, 1, 0) == 0, "not readable while no signal is pending");

    check(raise(SIGUSR1) == 0, "raise(SIGUSR1)");
    check(poll(&pfd, 1, 1000) == 1 && (pfd.revents & POLLIN),
          "becomes readable once the signal is pending");

    struct signalfd_siginfo info;
    memset(&info, 0, sizeof(info));
    ssize_t amount = read(fd, &info, sizeof(info));
    check(amount == (ssize_t)sizeof(info), "read returns one full siginfo record");
    check(info.ssi_signo == (uint32_t)SIGUSR1, "the record names the signal that fired");

    /* The read consumed it, so the descriptor goes quiet again. */
    pfd.revents = 0;
    check(poll(&pfd, 1, 0) == 0, "reading consumes the pending signal");

    /* A second, different signal from the same mask. */
    check(raise(SIGUSR2) == 0, "raise(SIGUSR2)");
    memset(&info, 0, sizeof(info));
    amount = read(fd, &info, sizeof(info));
    check(amount == (ssize_t)sizeof(info) && info.ssi_signo == (uint32_t)SIGUSR2,
          "a second signal in the mask arrives too");

    /* Narrowing the mask on an existing descriptor is how a program changes
       what it watches without disturbing its event loop. */
    sigset_t narrow;
    sigemptyset(&narrow);
    sigaddset(&narrow, SIGUSR2);
    check(signalfd(fd, &narrow, 0) == fd, "signalfd(fd, ...) re-arms the mask");

    check(raise(SIGUSR1) == 0, "raise a signal no longer in the mask");
    pfd.revents = 0;
    check(poll(&pfd, 1, 0) == 0, "a signal outside the mask is not reported");

    close(fd);
    if (failures) {
        printf("signalfd-test: FAIL (%d)\n", failures);
        return 1;
    }
    printf("signalfd-test: PASS\n");
    return 0;
}
