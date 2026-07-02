#include <stddef.h>
#include <stdint.h>
#include "tunix_libc.h"
#include <tunix/input_event.h>

#define MAX_INPUT_FDS 2U
#define EVENTS_PER_READ 16U

struct monitored_input {
    int fd;
    const char *path;
    struct tunix_input_device_info info;
};

static void print_number(long value) {
    t_print_long(value);
}

static const char *event_type_name(uint16_t type) {
    switch (type) {
        case TUNIX_EV_SYN: return "SYN";
        case TUNIX_EV_KEY: return "KEY";
        case TUNIX_EV_REL: return "REL";
        default: return "UNKNOWN";
    }
}

static const char *event_code_name(const struct tunix_input_event *event) {
    if (event->type == TUNIX_EV_SYN) {
        if (event->code == TUNIX_SYN_REPORT) return "REPORT";
        if (event->code == TUNIX_SYN_DROPPED) return "DROPPED";
    }
    if (event->type == TUNIX_EV_REL) {
        if (event->code == TUNIX_REL_X) return "X";
        if (event->code == TUNIX_REL_Y) return "Y";
        if (event->code == TUNIX_REL_WHEEL) return "WHEEL";
    }
    if (event->type == TUNIX_EV_KEY) {
        if (event->code == TUNIX_BTN_LEFT) return "BTN_LEFT";
        if (event->code == TUNIX_BTN_RIGHT) return "BTN_RIGHT";
        if (event->code == TUNIX_BTN_MIDDLE) return "BTN_MIDDLE";
        if (event->code == TUNIX_BTN_SIDE) return "BTN_SIDE";
        if (event->code == TUNIX_BTN_EXTRA) return "BTN_EXTRA";
    }
    return NULL;
}

static void print_device(const struct monitored_input *input) {
    t_puts("input-test: opened ");
    t_puts(input->path);
    t_puts(" (\"");
    t_puts(input->info.name);
    t_puts("\", device=");
    print_number((long)input->info.device_id);
    t_puts(", abi=");
    print_number((long)input->info.abi_version);
    t_puts(")\n");
}

static void print_event(const struct monitored_input *input,
                        const struct tunix_input_event *event) {
    t_puts(input->path);
    t_puts(": ");
    t_puts(event_type_name(event->type));
    t_puts(" ");
    const char *name = event_code_name(event);
    if (name) {
        t_puts(name);
    } else {
        t_puts("code=");
        print_number((long)event->code);
    }
    t_puts(" value=");
    print_number((long)event->value);
    t_puts(" time_ns=");
    print_number((long)event->time_ns);
    t_puts("\n");
}

static int open_input(struct monitored_input *input, const char *path) {
    input->fd = t_open(path, T_O_RDONLY | T_O_NONBLOCK, 0);
    input->path = path;
    if (input->fd < 0) return -1;
    t_memset(&input->info, 0, sizeof(input->info));
    if (t_ioctl(input->fd, TUNIX_EVIOCGINFO, &input->info) < 0) {
        t_close(input->fd);
        input->fd = -1;
        return -1;
    }
    print_device(input);
    return 0;
}

int main(int argc, char **argv) {
    struct monitored_input inputs[MAX_INPUT_FDS];
    struct t_pollfd pollfds[MAX_INPUT_FDS];
    unsigned count = 0;

    if (argc > 2) {
        t_puterr("usage: input-test [/dev/input/eventN]\n");
        return 2;
    }

    if (argc == 2) {
        if (open_input(&inputs[count], argv[1]) != 0) {
            t_puterr("input-test: cannot open input device\n");
            return 1;
        }
        count++;
    } else {
        if (open_input(&inputs[count], "/dev/input/event0") == 0) count++;
        if (count < MAX_INPUT_FDS &&
            open_input(&inputs[count], "/dev/input/event1") == 0) count++;
    }

    if (!count) {
        t_puterr("input-test: no event devices found\n");
        return 1;
    }

    t_puts("input-test: move the mouse or press keys; Ctrl-C exits\n");
    for (unsigned i = 0; i < count; i++) {
        pollfds[i].fd = inputs[i].fd;
        pollfds[i].events = T_POLLIN;
        pollfds[i].revents = 0;
    }

    for (;;) {
        int ready = t_poll(pollfds, count, -1);
        if (ready == -T_EINTR) continue;
        if (ready < 0) {
            t_puterr("input-test: poll failed\n");
            return 1;
        }

        for (unsigned i = 0; i < count; i++) {
            if (!(pollfds[i].revents & T_POLLIN)) continue;
            for (;;) {
                struct tunix_input_event events[EVENTS_PER_READ];
                long amount = t_read(inputs[i].fd, events, sizeof(events));
                if (amount == -T_EAGAIN) break;
                if (amount < 0) {
                    t_puterr("input-test: read failed\n");
                    return 1;
                }
                if (amount == 0) break;
                if ((size_t)amount % sizeof(events[0]) != 0U) {
                    t_puterr("input-test: malformed event stream\n");
                    return 1;
                }
                size_t event_count = (size_t)amount / sizeof(events[0]);
                for (size_t event = 0; event < event_count; event++)
                    print_event(&inputs[i], &events[event]);
            }
        }
    }
}
