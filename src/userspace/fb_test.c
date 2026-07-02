#include <stddef.h>
#include <stdint.h>
#include "tunix_libc.h"
#include <tunix/framebuffer.h>
#include <tunix/input_event.h>

#define CURSOR_WIDTH 16
#define CURSOR_HEIGHT 22
#define EVENT_BATCH 32U

struct surface {
    uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint32_t pitch;
    const struct tunix_fb_info *info;
};

static uint32_t component_mask(uint32_t size) {
    if (!size) return 0;
    if (size >= 32U) return UINT32_MAX;
    return (1U << size) - 1U;
}

static uint32_t scale_component(uint8_t value, uint32_t size) {
    uint32_t maximum = component_mask(size);
    if (!maximum) return 0;
    return ((uint32_t)value * maximum + 127U) / 255U;
}

static uint32_t pack_rgb(const struct tunix_fb_info *info,
                         uint8_t red, uint8_t green, uint8_t blue) {
    return (scale_component(red, info->red_mask_size) << info->red_field_position) |
           (scale_component(green, info->green_mask_size) << info->green_field_position) |
           (scale_component(blue, info->blue_mask_size) << info->blue_field_position);
}

static void put_pixel(struct surface *surface, int x, int y, uint32_t pixel) {
    if (!surface || x < 0 || y < 0 || (uint32_t)x >= surface->width ||
        (uint32_t)y >= surface->height) return;
    uint32_t *row = (uint32_t *)(void *)(surface->pixels + (uint64_t)y * surface->pitch);
    row[x] = pixel;
}

static void fill_rect(struct surface *surface, int x, int y, int width, int height,
                      uint32_t pixel) {
    if (!surface || width <= 0 || height <= 0) return;
    if (x < 0) { width += x; x = 0; }
    if (y < 0) { height += y; y = 0; }
    if (x >= (int)surface->width || y >= (int)surface->height) return;
    if (width > (int)surface->width - x) width = (int)surface->width - x;
    if (height > (int)surface->height - y) height = (int)surface->height - y;
    if (width <= 0 || height <= 0) return;

    for (int row_index = 0; row_index < height; row_index++) {
        uint32_t *row = (uint32_t *)(void *)(surface->pixels +
                        (uint64_t)(y + row_index) * surface->pitch);
        for (int column = 0; column < width; column++) row[x + column] = pixel;
    }
}

static void draw_frame(struct surface *surface, int x, int y, int width, int height,
                       int thickness, uint32_t pixel) {
    fill_rect(surface, x, y, width, thickness, pixel);
    fill_rect(surface, x, y + height - thickness, width, thickness, pixel);
    fill_rect(surface, x, y, thickness, height, pixel);
    fill_rect(surface, x + width - thickness, y, thickness, height, pixel);
}

static void draw_background(struct surface *surface) {
    const struct tunix_fb_info *info = surface->info;
    for (uint32_t y = 0; y < surface->height; y++) {
        uint32_t *row = (uint32_t *)(void *)(surface->pixels + (uint64_t)y * surface->pitch);
        for (uint32_t x = 0; x < surface->width; x++) {
            uint8_t red = (uint8_t)(10U + (x * 24U) / surface->width);
            uint8_t green = (uint8_t)(18U + (y * 34U) / surface->height);
            uint8_t blue = (uint8_t)(34U + ((x + y) * 52U) /
                                    (surface->width + surface->height));
            row[x] = pack_rgb(info, red, green, blue);
        }
    }

    uint32_t panel = pack_rgb(info, 17, 27, 46);
    uint32_t panel_light = pack_rgb(info, 24, 39, 64);
    uint32_t border = pack_rgb(info, 75, 112, 155);
    uint32_t accent = pack_rgb(info, 91, 174, 232);
    uint32_t muted = pack_rgb(info, 46, 65, 91);

    int margin = surface->width >= 1000U ? 42 : 24;
    int top_height = surface->height >= 700U ? 58 : 46;
    fill_rect(surface, 0, 0, (int)surface->width, top_height, panel);
    fill_rect(surface, margin, top_height + margin,
              (int)surface->width - margin * 2,
              (int)surface->height - top_height - margin * 2, panel_light);
    draw_frame(surface, margin, top_height + margin,
               (int)surface->width - margin * 2,
               (int)surface->height - top_height - margin * 2, 2, border);

    fill_rect(surface, margin + 24, 17, 16, 16, accent);
    fill_rect(surface, margin + 48, 20, 90, 10, muted);

    int card_width = (int)surface->width / 3;
    int card_height = (int)surface->height / 4;
    int card_x = ((int)surface->width - card_width) / 2;
    int card_y = ((int)surface->height - card_height) / 2;
    fill_rect(surface, card_x, card_y, card_width, card_height, panel);
    draw_frame(surface, card_x, card_y, card_width, card_height, 2, accent);
    fill_rect(surface, card_x + 24, card_y + 28, card_width - 48, 12, accent);
    fill_rect(surface, card_x + 24, card_y + 58, card_width - 86, 8, muted);
    fill_rect(surface, card_x + 24, card_y + 78, card_width - 126, 8, muted);

    for (int index = 0; index < 5; index++) {
        int box_x = margin + 26 + index * 34;
        fill_rect(surface, box_x, (int)surface->height - margin - 28,
                  22, 10, index == 0 ? accent : muted);
    }
}

static void copy_rect_to_front(const struct surface *back, struct surface *front,
                               int x, int y, int width, int height) {
    if (x < 0) { width += x; x = 0; }
    if (y < 0) { height += y; y = 0; }
    if (x >= (int)back->width || y >= (int)back->height) return;
    if (width > (int)back->width - x) width = (int)back->width - x;
    if (height > (int)back->height - y) height = (int)back->height - y;
    if (width <= 0 || height <= 0) return;

    for (int row = 0; row < height; row++) {
        const void *source = back->pixels + (uint64_t)(y + row) * back->pitch +
                             (uint64_t)x * 4U;
        void *destination = front->pixels + (uint64_t)(y + row) * front->pitch +
                            (uint64_t)x * 4U;
        t_memcpy(destination, source, (size_t)width * 4U);
    }
}

static int cursor_shape(int x, int y) {
    if (x < 0 || y < 0 || x >= CURSOR_WIDTH || y >= CURSOR_HEIGHT) return 0;
    if (x == 0 && y < 18) return 2;
    if (y == x && y < 15) return 2;
    if (x == 1 && y < 17) return 1;
    if (x > 1 && y > x && y < 16 && x < 9) return 1;
    if (y >= 13 && y <= 20 && x >= 5 && x <= 8) return 1;
    if ((y == 16 || y == 21) && x >= 4 && x <= 9) return 2;
    if ((x == 4 || x == 9) && y >= 15 && y <= 21) return 2;
    return 0;
}

static void draw_cursor(struct surface *front, int x, int y, uint32_t buttons) {
    uint32_t outline = pack_rgb(front->info, 3, 7, 12);
    uint32_t fill = buttons ? pack_rgb(front->info, 91, 174, 232) :
                              pack_rgb(front->info, 245, 250, 255);
    for (int row = 0; row < CURSOR_HEIGHT; row++) {
        for (int column = 0; column < CURSOR_WIDTH; column++) {
            int shape = cursor_shape(column, row);
            if (shape) put_pixel(front, x + column, y + row,
                                 shape == 2 ? outline : fill);
        }
    }
}

static void draw_button_status(struct surface *back, uint32_t buttons) {
    int x = 24;
    int y = (int)back->height - 50;
    uint32_t off = pack_rgb(back->info, 46, 65, 91);
    uint32_t on = pack_rgb(back->info, 91, 174, 232);
    fill_rect(back, x - 8, y - 8, 112, 34, pack_rgb(back->info, 17, 27, 46));
    for (int index = 0; index < 5; index++)
        fill_rect(back, x + index * 20, y, 14, 14,
                  (buttons & (1U << index)) ? on : off);
}

static uint32_t button_bit(uint16_t code) {
    if (code == TUNIX_BTN_LEFT) return 1U << 0;
    if (code == TUNIX_BTN_RIGHT) return 1U << 1;
    if (code == TUNIX_BTN_MIDDLE) return 1U << 2;
    if (code == TUNIX_BTN_SIDE) return 1U << 3;
    if (code == TUNIX_BTN_EXTRA) return 1U << 4;
    return 0;
}

static void flush_rect(int fb_fd, int x, int y, int width, int height) {
    if (width <= 0 || height <= 0) return;
    struct tunix_fb_rect rectangle = {
        .x = (uint32_t)x,
        .y = (uint32_t)y,
        .width = (uint32_t)width,
        .height = (uint32_t)height
    };
    (void)t_ioctl(fb_fd, TUNIX_FBIO_FLUSH, &rectangle);
}

int main(void) {
    int result = 1;
    int fb_fd = -1;
    int keyboard_fd = -1;
    int mouse_fd = -1;
    int graphics_active = 0;
    void *mapping = T_MAP_FAILED;
    void *backing = T_MAP_FAILED;
    struct tunix_fb_info info;

    fb_fd = t_open("/dev/fb0", T_O_RDWR, 0);
    if (fb_fd < 0) {
        t_puterr("fb-test: cannot open /dev/fb0\n");
        goto cleanup;
    }
    t_memset(&info, 0, sizeof(info));
    if (t_ioctl(fb_fd, TUNIX_FBIO_GET_INFO, &info) < 0 ||
        info.abi_version != TUNIX_FB_ABI_VERSION ||
        info.bits_per_pixel != 32U || !info.framebuffer_size ||
        !info.mapping_size || info.memory_offset > info.mapping_size ||
        info.framebuffer_size > info.mapping_size - info.memory_offset) {
        t_puterr("fb-test: unsupported framebuffer ABI\n");
        goto cleanup;
    }

    keyboard_fd = t_open("/dev/input/event0", T_O_RDONLY | T_O_NONBLOCK, 0);
    mouse_fd = t_open("/dev/input/event1", T_O_RDONLY | T_O_NONBLOCK, 0);

    uint32_t mode = TUNIX_FB_MODE_GRAPHICS;
    if (t_ioctl(fb_fd, TUNIX_FBIO_SET_MODE, &mode) < 0) {
        t_puterr("fb-test: framebuffer is busy or not writable\n");
        goto cleanup;
    }
    graphics_active = 1;

    mapping = t_mmap(NULL, (size_t)info.mapping_size,
                     T_PROT_READ | T_PROT_WRITE, T_MAP_SHARED, fb_fd, 0);
    if (mapping == T_MAP_FAILED) goto cleanup;
    backing = t_mmap(NULL, (size_t)info.framebuffer_size,
                     T_PROT_READ | T_PROT_WRITE,
                     T_MAP_PRIVATE | T_MAP_ANONYMOUS, -1, 0);
    if (backing == T_MAP_FAILED) goto cleanup;

    struct surface front = {
        .pixels = (uint8_t *)mapping + info.memory_offset,
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
        .info = &info
    };
    struct surface back = {
        .pixels = (uint8_t *)backing,
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
        .info = &info
    };

    draw_background(&back);
    draw_button_status(&back, 0);
    copy_rect_to_front(&back, &front, 0, 0, (int)info.width, (int)info.height);

    int cursor_x = (int)info.width / 2;
    int cursor_y = (int)info.height / 2;
    uint32_t buttons = 0;
    draw_cursor(&front, cursor_x, cursor_y, buttons);
    (void)t_ioctl(fb_fd, TUNIX_FBIO_FLUSH, NULL);

    struct t_pollfd poll_fds[2];
    unsigned poll_count = 0;
    if (keyboard_fd >= 0) {
        poll_fds[poll_count].fd = keyboard_fd;
        poll_fds[poll_count].events = T_POLLIN;
        poll_fds[poll_count].revents = 0;
        poll_count++;
    }
    if (mouse_fd >= 0) {
        poll_fds[poll_count].fd = mouse_fd;
        poll_fds[poll_count].events = T_POLLIN;
        poll_fds[poll_count].revents = 0;
        poll_count++;
    }

    if (!poll_count) {
        t_sleep_ms(3000);
        result = 0;
        goto cleanup;
    }

    int running = 1;
    while (running) {
        int ready = t_poll(poll_fds, poll_count, -1);
        if (ready == -T_EINTR) continue;
        if (ready < 0) break;

        for (unsigned descriptor = 0; descriptor < poll_count; descriptor++) {
            if (!(poll_fds[descriptor].revents & T_POLLIN)) continue;
            for (;;) {
                struct tunix_input_event events[EVENT_BATCH];
                long amount = t_read(poll_fds[descriptor].fd, events, sizeof(events));
                if (amount == -T_EAGAIN) break;
                if (amount <= 0 || (size_t)amount % sizeof(events[0]) != 0U) {
                    running = 0;
                    break;
                }

                int old_x = cursor_x;
                int old_y = cursor_y;
                uint32_t old_buttons = buttons;
                size_t count = (size_t)amount / sizeof(events[0]);
                for (size_t index = 0; index < count; index++) {
                    const struct tunix_input_event *event = &events[index];
                    if (event->type == TUNIX_EV_KEY &&
                        event->code == TUNIX_KEY_ESC && event->value == 1) {
                        running = 0;
                    } else if (event->type == TUNIX_EV_REL) {
                        if (event->code == TUNIX_REL_X) cursor_x += event->value;
                        else if (event->code == TUNIX_REL_Y) cursor_y += event->value;
                    } else if (event->type == TUNIX_EV_KEY) {
                        uint32_t bit = button_bit(event->code);
                        if (bit) {
                            if (event->value) buttons |= bit;
                            else buttons &= ~bit;
                        }
                    }
                }

                if (cursor_x < 0) cursor_x = 0;
                if (cursor_y < 0) cursor_y = 0;
                if (cursor_x > (int)info.width - CURSOR_WIDTH)
                    cursor_x = (int)info.width - CURSOR_WIDTH;
                if (cursor_y > (int)info.height - CURSOR_HEIGHT)
                    cursor_y = (int)info.height - CURSOR_HEIGHT;

                if (cursor_x != old_x || cursor_y != old_y || buttons != old_buttons) {
                    copy_rect_to_front(&back, &front, old_x, old_y,
                                       CURSOR_WIDTH, CURSOR_HEIGHT);
                    flush_rect(fb_fd, old_x, old_y, CURSOR_WIDTH, CURSOR_HEIGHT);
                    if (buttons != old_buttons) {
                        draw_button_status(&back, buttons);
                        copy_rect_to_front(&back, &front, 16, (int)info.height - 58,
                                           120, 42);
                        flush_rect(fb_fd, 16, (int)info.height - 58, 120, 42);
                    }
                    draw_cursor(&front, cursor_x, cursor_y, buttons);
                    flush_rect(fb_fd, cursor_x, cursor_y,
                               CURSOR_WIDTH, CURSOR_HEIGHT);
                }
            }
        }
    }
    result = 0;

cleanup:
    if (graphics_active) {
        uint32_t console_mode = TUNIX_FB_MODE_CONSOLE;
        (void)t_ioctl(fb_fd, TUNIX_FBIO_SET_MODE, &console_mode);
    }
    if (backing != T_MAP_FAILED) (void)t_munmap(backing, (size_t)info.framebuffer_size);
    if (mapping != T_MAP_FAILED) (void)t_munmap(mapping, (size_t)info.mapping_size);
    if (mouse_fd >= 0) (void)t_close(mouse_fd);
    if (keyboard_fd >= 0) (void)t_close(keyboard_fd);
    if (fb_fd >= 0) (void)t_close(fb_fd);
    if (result == 0) t_puts("fb-test: PASS framebuffer mmap and input demo\n");
    return result;
}
