#include <stddef.h>
#include <stdint.h>
#include "include/heap.h"
#include "include/input.h"
#include "include/io.h"
#include "include/kstring.h"
#include "include/time.h"
#include "include/tty.h"
#include "../include/tunix/input_event.h"

#define EAGAIN 11
#define EINVAL 22

#define PS2_STATUS_PORT  0x64U
#define PS2_COMMAND_PORT 0x64U
#define PS2_DATA_PORT    0x60U

#define PS2_STATUS_OUTPUT_FULL 0x01U
#define PS2_STATUS_INPUT_FULL  0x02U
#define PS2_STATUS_AUX_DATA    0x20U
#define PS2_TIMEOUT 200000U

#define PS2_ACK 0xFAU
#define PS2_MOUSE_WRITE 0xD4U

#define RAW_INPUT_CAPACITY 256U
#define INPUT_READER_CAPACITY 128U
#define INPUT_KEY_STATE_SIZE 256U

struct input_reader {
    unsigned device_id;
    struct tunix_input_event events[INPUT_READER_CAPACITY];
    size_t head;
    size_t tail;
    size_t count;
    struct input_reader *next;
};

static uint8_t raw_input[RAW_INPUT_CAPACITY];
static size_t raw_head;
static size_t raw_tail;
static size_t raw_count;
static unsigned raw_listeners;

static struct input_reader *input_readers;
static uint8_t key_down[INPUT_KEY_STATE_SIZE];
static unsigned keyboard_extended;
static unsigned keyboard_pause_bytes;

static uint8_t mouse_packet[4];
static unsigned mouse_packet_index;
static unsigned mouse_packet_size;
static unsigned mouse_device_id;
static unsigned mouse_present;
static uint8_t mouse_buttons;

static uint64_t interrupt_save(void) {
    uint64_t flags;
    __asm__ volatile("pushfq; popq %0; cli" : "=r"(flags) : : "memory");
    return flags;
}

static void interrupt_restore(uint64_t flags) {
    __asm__ volatile("pushq %0; popfq" : : "r"(flags) : "memory", "cc");
}

static int ps2_wait_write(void) {
    for (unsigned i = 0; i < PS2_TIMEOUT; i++) {
        if (!(inb(PS2_STATUS_PORT) & PS2_STATUS_INPUT_FULL)) return 0;
        __asm__ volatile("pause");
    }
    return -1;
}

static int ps2_wait_read(int expect_aux, uint8_t *value) {
    for (unsigned i = 0; i < PS2_TIMEOUT; i++) {
        uint8_t status = inb(PS2_STATUS_PORT);
        if (status & PS2_STATUS_OUTPUT_FULL) {
            uint8_t data = inb(PS2_DATA_PORT);
            int is_aux = (status & PS2_STATUS_AUX_DATA) != 0;
            if (expect_aux < 0 || is_aux == expect_aux) {
                if (value) *value = data;
                return 0;
            }
            continue;
        }
        __asm__ volatile("pause");
    }
    return -1;
}

static int ps2_command(uint8_t command) {
    if (ps2_wait_write() != 0) return -1;
    outb(PS2_COMMAND_PORT, command);
    return 0;
}

static int ps2_write_data(uint8_t value) {
    if (ps2_wait_write() != 0) return -1;
    outb(PS2_DATA_PORT, value);
    return 0;
}

static int ps2_read_config(uint8_t *config) {
    if (!config || ps2_command(0x20U) != 0) return -1;
    return ps2_wait_read(0, config);
}

static int ps2_write_config(uint8_t config) {
    if (ps2_command(0x60U) != 0) return -1;
    return ps2_write_data(config);
}

static void ps2_flush(void) {
    unsigned remaining = 64U;
    while (remaining-- && (inb(PS2_STATUS_PORT) & PS2_STATUS_OUTPUT_FULL))
        (void)inb(PS2_DATA_PORT);
}

static int ps2_keyboard_command(uint8_t command) {
    uint8_t response;
    if (ps2_write_data(command) != 0 || ps2_wait_read(0, &response) != 0)
        return -1;
    return response == PS2_ACK ? 0 : -1;
}

static int ps2_mouse_command(uint8_t command) {
    uint8_t response;
    if (ps2_command(PS2_MOUSE_WRITE) != 0 || ps2_write_data(command) != 0 ||
        ps2_wait_read(1, &response) != 0)
        return -1;
    return response == PS2_ACK ? 0 : -1;
}

static int ps2_mouse_set_sample_rate(uint8_t rate) {
    if (ps2_mouse_command(0xF3U) != 0) return -1;
    return ps2_mouse_command(rate);
}

static int ps2_mouse_get_id(uint8_t *device_id) {
    if (!device_id || ps2_mouse_command(0xF2U) != 0) return -1;
    return ps2_wait_read(1, device_id);
}

static unsigned ps2_mouse_negotiate_wheel(void) {
    uint8_t device_id = 0;
    if (ps2_mouse_set_sample_rate(200U) != 0 ||
        ps2_mouse_set_sample_rate(100U) != 0 ||
        ps2_mouse_set_sample_rate(80U) != 0 ||
        ps2_mouse_get_id(&device_id) != 0)
        return 0U;

    if (device_id == 3U) {
        uint8_t explorer_id = device_id;
        if (ps2_mouse_set_sample_rate(200U) == 0 &&
            ps2_mouse_set_sample_rate(200U) == 0 &&
            ps2_mouse_set_sample_rate(80U) == 0 &&
            ps2_mouse_get_id(&explorer_id) == 0 && explorer_id == 4U)
            return 4U;
        return 3U;
    }
    return device_id == 4U ? 4U : 0U;
}

static void reader_push(struct input_reader *reader,
                        const struct tunix_input_event *event) {
    if (!reader || !event) return;
    if (reader->count == INPUT_READER_CAPACITY) {
        reader->head = 0;
        reader->tail = 0;
        reader->count = 0;
        struct tunix_input_event dropped = {
            .time_ns = event->time_ns,
            .type = TUNIX_EV_SYN,
            .code = TUNIX_SYN_DROPPED,
            .value = 0
        };
        reader->events[reader->tail] = dropped;
        reader->tail = (reader->tail + 1U) % INPUT_READER_CAPACITY;
        reader->count = 1U;
    }
    reader->events[reader->tail] = *event;
    reader->tail = (reader->tail + 1U) % INPUT_READER_CAPACITY;
    reader->count++;
}

static void input_emit_at(unsigned device_id, uint64_t timestamp,
                          uint16_t type, uint16_t code, int32_t value) {
    struct tunix_input_event event = {
        .time_ns = timestamp,
        .type = type,
        .code = code,
        .value = value
    };
    for (struct input_reader *reader = input_readers; reader; reader = reader->next) {
        if (reader->device_id == device_id) reader_push(reader, &event);
    }
}

static void input_sync_at(unsigned device_id, uint64_t timestamp) {
    input_emit_at(device_id, timestamp, TUNIX_EV_SYN, TUNIX_SYN_REPORT, 0);
}

static void raw_push(uint8_t value) {
    if (!raw_listeners) return;
    if (raw_count == RAW_INPUT_CAPACITY) {
        raw_head = (raw_head + 1U) % RAW_INPUT_CAPACITY;
        raw_count--;
    }
    raw_input[raw_tail] = value;
    raw_tail = (raw_tail + 1U) % RAW_INPUT_CAPACITY;
    raw_count++;
}

static uint16_t extended_keycode(uint8_t scan) {
    switch (scan) {
        case 0x1CU: return TUNIX_KEY_KPENTER;
        case 0x1DU: return TUNIX_KEY_RIGHTCTRL;
        case 0x35U: return TUNIX_KEY_KPSLASH;
        case 0x37U: return TUNIX_KEY_SYSRQ;
        case 0x38U: return TUNIX_KEY_RIGHTALT;
        case 0x47U: return TUNIX_KEY_HOME;
        case 0x48U: return TUNIX_KEY_UP;
        case 0x49U: return TUNIX_KEY_PAGEUP;
        case 0x4BU: return TUNIX_KEY_LEFT;
        case 0x4DU: return TUNIX_KEY_RIGHT;
        case 0x4FU: return TUNIX_KEY_END;
        case 0x50U: return TUNIX_KEY_DOWN;
        case 0x51U: return TUNIX_KEY_PAGEDOWN;
        case 0x52U: return TUNIX_KEY_INSERT;
        case 0x53U: return TUNIX_KEY_DELETE;
        case 0x5BU: return TUNIX_KEY_LEFTMETA;
        case 0x5CU: return TUNIX_KEY_RIGHTMETA;
        case 0x5DU: return TUNIX_KEY_COMPOSE;
        default: return TUNIX_KEY_RESERVED;
    }
}

static void keyboard_emit_key(uint16_t keycode, int released) {
    if (!keycode || keycode >= INPUT_KEY_STATE_SIZE) return;
    int32_t value;
    if (released) {
        value = 0;
        key_down[keycode] = 0;
    } else if (key_down[keycode]) {
        value = 2;
    } else {
        value = 1;
        key_down[keycode] = 1;
    }
    uint64_t timestamp = time_uptime_ns();
    input_emit_at(TUNIX_INPUT_DEVICE_KEYBOARD, timestamp,
                  TUNIX_EV_KEY, keycode, value);
    input_sync_at(TUNIX_INPUT_DEVICE_KEYBOARD, timestamp);
}

static int keyboard_handle_event_byte(uint8_t byte) {
    if (keyboard_pause_bytes) {
        keyboard_pause_bytes--;
        return 0;
    }
    if (byte == 0xE1U) {
        keyboard_pause_bytes = 5U;
        uint64_t timestamp = time_uptime_ns();
        input_emit_at(TUNIX_INPUT_DEVICE_KEYBOARD, timestamp,
                      TUNIX_EV_KEY, TUNIX_KEY_PAUSE, 1);
        input_sync_at(TUNIX_INPUT_DEVICE_KEYBOARD, timestamp);
        input_emit_at(TUNIX_INPUT_DEVICE_KEYBOARD, timestamp,
                      TUNIX_EV_KEY, TUNIX_KEY_PAUSE, 0);
        input_sync_at(TUNIX_INPUT_DEVICE_KEYBOARD, timestamp);
        return 1;
    }
    if (byte == 0xE0U) {
        keyboard_extended = 1U;
        return 1;
    }

    int released = (byte & 0x80U) != 0;
    uint8_t scan = byte & 0x7FU;
    uint16_t keycode;
    if (keyboard_extended) {
        keyboard_extended = 0;
        /* PrintScreen emits fake extended shifts; they are not real keys. */
        if (scan == 0x2AU || scan == 0x36U) return 1;
        keycode = extended_keycode(scan);
    } else {
        keycode = scan <= TUNIX_KEY_F12 ? scan : TUNIX_KEY_RESERVED;
    }
    keyboard_emit_key(keycode, released);
    return 1;
}

static void mouse_emit_button(uint64_t timestamp, uint8_t changed,
                              uint8_t state, uint8_t bit, uint16_t code) {
    if (!(changed & bit)) return;
    input_emit_at(TUNIX_INPUT_DEVICE_MOUSE, timestamp, TUNIX_EV_KEY, code,
                  (state & bit) ? 1 : 0);
}

static void mouse_complete_packet(void) {
    uint8_t flags = mouse_packet[0];
    uint8_t new_buttons = flags & 0x07U;
    int x = (int)mouse_packet[1] - ((flags & 0x10U) ? 256 : 0);
    int y = (int)mouse_packet[2] - ((flags & 0x20U) ? 256 : 0);
    int wheel = 0;

    if (mouse_packet_size == 4U) {
        uint8_t fourth = mouse_packet[3];
        wheel = (int)(fourth & 0x0FU);
        if (wheel & 0x08) wheel -= 16;
        if (mouse_device_id == 4U) {
            if (fourth & 0x10U) new_buttons |= 0x08U;
            if (fourth & 0x20U) new_buttons |= 0x10U;
        }
    }

    if (flags & 0xC0U) {
        x = 0;
        y = 0;
    }

    uint8_t changed = new_buttons ^ mouse_buttons;
    if (!x && !y && !wheel && !changed) return;

    uint64_t timestamp = time_uptime_ns();
    if (x) input_emit_at(TUNIX_INPUT_DEVICE_MOUSE, timestamp, TUNIX_EV_REL,
                         TUNIX_REL_X, x);
    if (y) input_emit_at(TUNIX_INPUT_DEVICE_MOUSE, timestamp, TUNIX_EV_REL,
                         TUNIX_REL_Y, -y);
    if (wheel) input_emit_at(TUNIX_INPUT_DEVICE_MOUSE, timestamp, TUNIX_EV_REL,
                             TUNIX_REL_WHEEL, wheel);
    mouse_emit_button(timestamp, changed, new_buttons, 0x01U, TUNIX_BTN_LEFT);
    mouse_emit_button(timestamp, changed, new_buttons, 0x02U, TUNIX_BTN_RIGHT);
    mouse_emit_button(timestamp, changed, new_buttons, 0x04U, TUNIX_BTN_MIDDLE);
    mouse_emit_button(timestamp, changed, new_buttons, 0x08U, TUNIX_BTN_SIDE);
    mouse_emit_button(timestamp, changed, new_buttons, 0x10U, TUNIX_BTN_EXTRA);
    mouse_buttons = new_buttons;
    input_sync_at(TUNIX_INPUT_DEVICE_MOUSE, timestamp);
}

static void mouse_handle_byte(uint8_t byte) {
    if (!mouse_present) return;
    if (mouse_packet_index == 0U && !(byte & 0x08U)) return;
    mouse_packet[mouse_packet_index++] = byte;
    if (mouse_packet_index == mouse_packet_size) {
        mouse_packet_index = 0;
        mouse_complete_packet();
    }
}

void input_init(void) {
    uint8_t config = 0;
    (void)ps2_command(0xADU);
    (void)ps2_command(0xA7U);
    ps2_flush();

    if (ps2_read_config(&config) != 0) config = 0;
    config &= (uint8_t)~0x03U;
    config |= 0x40U;
    (void)ps2_write_config(config);

    (void)ps2_command(0xAEU);
    (void)ps2_command(0xA8U);

    config |= 0x03U;
    config &= (uint8_t)~0x30U;
    config |= 0x40U;
    (void)ps2_write_config(config);

    (void)ps2_keyboard_command(0xF4U);

    mouse_present = ps2_mouse_command(0xF6U) == 0;
    mouse_device_id = 0U;
    mouse_packet_size = 3U;
    if (mouse_present) {
        mouse_device_id = ps2_mouse_negotiate_wheel();
        if (mouse_device_id == 3U || mouse_device_id == 4U)
            mouse_packet_size = 4U;
        if (ps2_mouse_command(0xF4U) != 0) mouse_present = 0;
    }

    raw_head = 0;
    raw_tail = 0;
    raw_count = 0;
    raw_listeners = 0;
    input_readers = NULL;
    memset(key_down, 0, sizeof(key_down));
    keyboard_extended = 0;
    keyboard_pause_bytes = 0;
    mouse_packet_index = 0;
    mouse_buttons = 0;
    tty_reset_keyboard_state();
}

static void input_drain_controller(void) {
    for (;;) {
        uint8_t status = inb(PS2_STATUS_PORT);
        if (!(status & PS2_STATUS_OUTPUT_FULL)) return;
        uint8_t value = inb(PS2_DATA_PORT);
        if (status & PS2_STATUS_AUX_DATA) {
            mouse_handle_byte(value);
        } else {
            raw_push(value);
            int pass_to_tty = keyboard_handle_event_byte(value);
            if (pass_to_tty) tty_handle_scancode(value);
        }
    }
}

void input_poll(void) {
    uint64_t flags = interrupt_save();
    input_drain_controller();
    interrupt_restore(flags);
}

void input_irq(void) {
    input_drain_controller();
}

int input_mouse_available(void) {
    return mouse_present != 0;
}

int input_get_device_info(unsigned device_id, struct tunix_input_device_info *info) {
    if (!info) return -EINVAL;
    memset(info, 0, sizeof(*info));
    info->abi_version = TUNIX_INPUT_ABI_VERSION;
    info->device_id = device_id;
    if (device_id == TUNIX_INPUT_DEVICE_KEYBOARD) {
        info->event_types = (1U << TUNIX_EV_SYN) | (1U << TUNIX_EV_KEY);
        info->capabilities = TUNIX_INPUT_CAP_KEYBOARD;
        memcpy(info->name, "Tunix PS/2 Keyboard", sizeof("Tunix PS/2 Keyboard"));
        return 0;
    }
    if (device_id == TUNIX_INPUT_DEVICE_MOUSE && mouse_present) {
        info->event_types = (1U << TUNIX_EV_SYN) | (1U << TUNIX_EV_KEY) |
                            (1U << TUNIX_EV_REL);
        info->relative_axes = (1U << TUNIX_REL_X) | (1U << TUNIX_REL_Y);
        info->capabilities = TUNIX_INPUT_CAP_POINTER;
        if (mouse_packet_size == 4U) {
            info->relative_axes |= 1U << TUNIX_REL_WHEEL;
            info->capabilities |= TUNIX_INPUT_CAP_WHEEL;
        }
        if (mouse_device_id == 4U)
            info->capabilities |= TUNIX_INPUT_CAP_EXTRA_BUTTONS;
        memcpy(info->name, "Tunix PS/2 Mouse", sizeof("Tunix PS/2 Mouse"));
        return 0;
    }
    return -EINVAL;
}

void input_scancode_open(void) {
    uint64_t flags = interrupt_save();
    raw_listeners++;
    interrupt_restore(flags);
}

void input_scancode_close(void) {
    uint64_t flags = interrupt_save();
    if (raw_listeners) raw_listeners--;
    if (!raw_listeners) {
        raw_head = 0;
        raw_tail = 0;
        raw_count = 0;
    }
    interrupt_restore(flags);
}

int input_scancodes_ready(void) {
    input_poll();
    uint64_t flags = interrupt_save();
    int ready = raw_count != 0;
    interrupt_restore(flags);
    return ready;
}

int64_t input_read_scancodes(size_t size, void *buffer) {
    if (!buffer) return -EINVAL;
    if (!size) return 0;
    input_poll();
    uint64_t flags = interrupt_save();
    if (!raw_count) {
        interrupt_restore(flags);
        return -EAGAIN;
    }
    uint8_t *out = (uint8_t *)buffer;
    size_t completed = 0;
    while (completed < size && raw_count) {
        out[completed++] = raw_input[raw_head];
        raw_head = (raw_head + 1U) % RAW_INPUT_CAPACITY;
        raw_count--;
    }
    interrupt_restore(flags);
    return (int64_t)completed;
}

struct input_reader *input_reader_open(unsigned device_id) {
    if (device_id != TUNIX_INPUT_DEVICE_KEYBOARD &&
        device_id != TUNIX_INPUT_DEVICE_MOUSE)
        return NULL;
    if (device_id == TUNIX_INPUT_DEVICE_MOUSE && !mouse_present) return NULL;

    struct input_reader *reader = (struct input_reader *)kmalloc(sizeof(*reader));
    if (!reader) return NULL;
    memset(reader, 0, sizeof(*reader));
    reader->device_id = device_id;

    uint64_t flags = interrupt_save();
    reader->next = input_readers;
    input_readers = reader;
    interrupt_restore(flags);
    return reader;
}

void input_reader_close(struct input_reader *reader) {
    if (!reader) return;
    uint64_t flags = interrupt_save();
    struct input_reader **link = &input_readers;
    while (*link && *link != reader) link = &(*link)->next;
    if (*link == reader) *link = reader->next;
    interrupt_restore(flags);
    kfree(reader);
}

int input_reader_ready(struct input_reader *reader) {
    if (!reader) return 0;
    input_poll();
    uint64_t flags = interrupt_save();
    int ready = reader->count != 0;
    interrupt_restore(flags);
    return ready;
}

int64_t input_reader_read(struct input_reader *reader, size_t size, void *buffer) {
    if (!reader || !buffer) return -EINVAL;
    if (size < sizeof(struct tunix_input_event)) return -EINVAL;
    input_poll();

    size_t event_capacity = size / sizeof(struct tunix_input_event);
    uint64_t flags = interrupt_save();
    if (!reader->count) {
        interrupt_restore(flags);
        return -EAGAIN;
    }

    struct tunix_input_event *out = (struct tunix_input_event *)buffer;
    size_t completed = 0;
    while (completed < event_capacity && reader->count) {
        out[completed++] = reader->events[reader->head];
        reader->head = (reader->head + 1U) % INPUT_READER_CAPACITY;
        reader->count--;
    }
    interrupt_restore(flags);
    return (int64_t)(completed * sizeof(struct tunix_input_event));
}
