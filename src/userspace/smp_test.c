/*
 * Does work actually run on more than one processor?
 *
 * The only honest way to answer that from user space is to time it. One child
 * does a fixed amount of arithmetic; then four children do the same amount
 * each, at the same time. On one processor the four take four times as long as
 * the one. On four they take roughly as long as the one did, and the ratio
 * between those two numbers is the speedup -- a number that cannot be faked by
 * a scheduler that is merely fast at switching.
 *
 * The threshold is deliberately far below four. Under emulation and with the
 * kernel serialised behind a single lock, a real four-processor machine lands
 * near three; anything at or above two proves the point, and one processor
 * cannot reach it however hard it tries.
 */
#include "tunix_libc.h"

#define WORKERS 4
#define SPIN_ITERATIONS 1000000000ULL
#define SPEEDUP_THRESHOLD_PERCENT 200ULL

static void log_line(const char *text) {
    t_puts(text);
    int fd = t_open("/dev/kmsg", T_O_WRONLY, 0);
    if (fd < 0) return;
    (void)t_write(fd, text, t_strlen(text));
    t_close(fd);
}

static void log_number(const char *label, uint64_t value, const char *suffix) {
    char digits[24];
    int at = (int)sizeof(digits);
    digits[--at] = '\0';
    if (!value) digits[--at] = '0';
    while (value) {
        digits[--at] = (char)('0' + (value % 10ULL));
        value /= 10ULL;
    }
    t_puts(label);
    t_puts(digits + at);
    t_puts(suffix);
}

static void cpu_spin(void) {
    uint64_t iterations = SPIN_ITERATIONS;
    __asm__ volatile(
        "1:\n"
        "sub $1, %0\n"
        "jnz 1b\n"
        : "+r"(iterations)
        :
        : "cc", "memory");
}

static uint64_t now_ms(void) {
    struct t_timespec time = {0, 0};
    if (t_clock_gettime(&time) != 0) return 0;
    return (uint64_t)time.tv_sec * 1000ULL + (uint64_t)time.tv_nsec / 1000000ULL;
}

/* Runs `count` children that each burn the same amount, and returns how long
   the slowest of them took from the parent's point of view. */
static uint64_t run_workers(int count) {
    long children[WORKERS];
    uint64_t started = now_ms();

    for (int index = 0; index < count; index++) {
        long child = t_fork();
        if (child < 0) return 0;
        if (child == 0) {
            cpu_spin();
            t_exit(0);
        }
        children[index] = child;
    }

    for (int index = 0; index < count; index++) {
        int status = 0;
        while (t_waitpid(children[index], &status, 0) < 0) t_yield();
        if (((status >> 8) & 0xff) != 0) return 0;
    }
    return now_ms() - started;
}

int main(int argc, char **argv, char **envp) {
    (void)argc;
    (void)argv;
    (void)envp;

    /* Thrown away. The first fork of a process pays for the copy-on-write
       breaks the later ones do not, and charging that to the single-worker
       run alone would flatter the ratio. */
    (void)run_workers(1);

    uint64_t alone = run_workers(1);
    if (!alone) {
        log_line("SMPTEST: FAIL single worker\n");
        return 1;
    }
    uint64_t together = run_workers(WORKERS);
    if (!together) {
        log_line("SMPTEST: FAIL parallel workers\n");
        return 1;
    }

    log_number("SMPTEST: one worker ", alone, " ms\n");
    log_number("SMPTEST: ", WORKERS, " workers ");
    log_number("", together, " ms\n");

    /* Serial time is what the same work would have cost one after another. */
    uint64_t serial = alone * WORKERS;
    uint64_t speedup = (serial * 100ULL) / together;
    log_number("SMPTEST: speedup ", speedup, " percent\n");

    if (speedup >= SPEEDUP_THRESHOLD_PERCENT) {
        log_line("SMPTEST: PASS work ran on more than one cpu\n");
        return 0;
    }
    log_line("SMPTEST: FAIL work was serialised\n");
    return 1;
}
