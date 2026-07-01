#include <stdint.h>
#include "tunix_libc.h"

#define NS_PER_SECOND 1000000000ULL
#define UINT64_MAX_VALUE (~(uint64_t)0)

static int digit(char value) {
    return value >= '0' && value <= '9';
}

static int parse_duration(const char *text, uint64_t *nanoseconds) {
    if (!text || !*text || !nanoseconds) return -1;

    uint64_t seconds = 0;
    uint64_t fraction = 0;
    unsigned fraction_digits = 0;
    int have_integer = 0;

    while (digit(*text)) {
        have_integer = 1;
        unsigned value = (unsigned)(*text - '0');
        if (seconds > (UINT64_MAX_VALUE - value) / 10ULL) return -1;
        seconds = seconds * 10ULL + value;
        text++;
    }

    if (*text == '.') {
        text++;
        while (digit(*text)) {
            if (fraction_digits < 9U) {
                fraction = fraction * 10ULL + (unsigned)(*text - '0');
                fraction_digits++;
            }
            text++;
        }
    }

    if (!have_integer && fraction_digits == 0U) return -1;

    uint64_t multiplier = 1;
    if (*text == 's') {
        text++;
    } else if (*text == 'm') {
        multiplier = 60ULL;
        text++;
    } else if (*text == 'h') {
        multiplier = 60ULL * 60ULL;
        text++;
    } else if (*text == 'd') {
        multiplier = 24ULL * 60ULL * 60ULL;
        text++;
    }
    if (*text != '\0') return -1;

    while (fraction_digits < 9U) {
        fraction *= 10ULL;
        fraction_digits++;
    }

    if (seconds > UINT64_MAX_VALUE / multiplier) return -1;
    seconds *= multiplier;
    if (seconds > UINT64_MAX_VALUE / NS_PER_SECOND) return -1;
    uint64_t total = seconds * NS_PER_SECOND;

    if (fraction) {
        if (fraction > UINT64_MAX_VALUE / multiplier) return -1;
        uint64_t fractional_ns = fraction * multiplier;
        if (total > UINT64_MAX_VALUE - fractional_ns) return -1;
        total += fractional_ns;
    }

    *nanoseconds = total;
    return 0;
}

static uint64_t timespec_to_ns(const struct t_timespec *value) {
    if (!value || value->tv_sec < 0 || value->tv_nsec < 0) return 0;
    uint64_t seconds = (uint64_t)value->tv_sec;
    if (seconds > UINT64_MAX_VALUE / NS_PER_SECOND) return UINT64_MAX_VALUE;
    uint64_t result = seconds * NS_PER_SECOND;
    uint64_t nanos = (uint64_t)value->tv_nsec;
    return result > UINT64_MAX_VALUE - nanos ? UINT64_MAX_VALUE : result + nanos;
}

static void ns_to_timespec(uint64_t value, struct t_timespec *result) {
    result->tv_sec = (int64_t)(value / NS_PER_SECOND);
    result->tv_nsec = (int64_t)(value % NS_PER_SECOND);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        t_puterr("usage: sleep SECONDS[.FRACTION][s|m|h|d]\n");
        return 2;
    }

    uint64_t duration;
    if (parse_duration(argv[1], &duration) != 0) {
        t_puterr("sleep: invalid duration\n");
        return 2;
    }

    struct t_timespec now;
    if (t_clock_gettime(&now) < 0) {
        t_puterr("sleep: clock_gettime failed\n");
        return 1;
    }
    uint64_t start = timespec_to_ns(&now);
    uint64_t deadline = start > UINT64_MAX_VALUE - duration ? UINT64_MAX_VALUE : start + duration;

    for (;;) {
        if (t_clock_gettime(&now) < 0) {
            t_puterr("sleep: clock_gettime failed\n");
            return 1;
        }
        uint64_t current = timespec_to_ns(&now);
        if (current >= deadline) return 0;

        struct t_timespec request;
        ns_to_timespec(deadline - current, &request);
        int result = t_nanosleep(&request, 0);
        if (result == 0 || result == -T_EINTR) continue;
        t_puterr("sleep: nanosleep failed\n");
        return 1;
    }
}
