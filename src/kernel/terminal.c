#include <stddef.h>
#include <stdint.h>
#include "include/framebuffer.h"
#include "include/kstring.h"
#include "include/vfs.h"
#include "include/terminal.h"
#include "include/terminal_font.h"

#define MAX_CONSOLE_COLS 224
#define MAX_CONSOLE_ROWS 80
#define CELL_BG_EXPLICIT 0x01U

struct console_cell {
    uint32_t codepoint;
    uint8_t flags;
    uint8_t reserved[3];
    uint32_t foreground;
    uint32_t background;
};

struct console_layout {
    uint32_t screen_width;
    uint32_t screen_height;
    uint32_t terminal_x;
    uint32_t terminal_y;
    uint32_t terminal_width;
    uint32_t terminal_height;
    uint32_t title_height;
    uint32_t content_x;
    uint32_t content_y;
    uint32_t cell_width;
    uint32_t cell_height;
    uint16_t columns;
    uint16_t rows;
};

static uint32_t wallpaper_backing[TUNIX_FRAMEBUFFER_MAX_WIDTH * TUNIX_FRAMEBUFFER_MAX_HEIGHT];
static struct console_cell console_cells[MAX_CONSOLE_COLS * MAX_CONSOLE_ROWS];
static struct console_cell primary_cells[MAX_CONSOLE_COLS * MAX_CONSOLE_ROWS];
static struct console_layout layout;
static int terminal_ready;
static int console_col;
static int console_row;
static uint32_t current_foreground;
static uint32_t current_background;
static uint8_t current_background_explicit;
static uint8_t current_bold;
static uint8_t current_reverse;
static int cursor_visible = 1;
static int alternate_active;
static int primary_col;
static int primary_row;
static int scroll_top;
static int scroll_bottom;
static int primary_scroll_top;
static int primary_scroll_bottom;

static const uint32_t ansi_palette[16] = {
    0x15161EU, 0xF7768EU, 0x9ECE6AU, 0xE0AF68U,
    0x7AA2F7U, 0xBB9AF7U, 0x7DCFFFU, 0xC0CAF5U,
    0x414868U, 0xFF899DU, 0xB9F27CU, 0xF4C97AU,
    0x8DB0FFU, 0xC7A9FFU, 0x9BE8FFU, 0xF4F7FFU
};

static uint32_t blend_rgb(uint32_t base, uint32_t overlay, uint8_t alpha) {
    uint32_t inverse = 255U - alpha;
    uint32_t red = (((base >> 16) & 0xFFU) * inverse +
                    ((overlay >> 16) & 0xFFU) * alpha) / 255U;
    uint32_t green = (((base >> 8) & 0xFFU) * inverse +
                      ((overlay >> 8) & 0xFFU) * alpha) / 255U;
    uint32_t blue = ((base & 0xFFU) * inverse +
                     (overlay & 0xFFU) * alpha) / 255U;
    return (red << 16) | (green << 8) | blue;
}

static uint32_t shade_rgb(uint32_t color, uint32_t numerator, uint32_t denominator) {
    uint32_t red = (((color >> 16) & 0xFFU) * numerator) / denominator;
    uint32_t green = (((color >> 8) & 0xFFU) * numerator) / denominator;
    uint32_t blue = ((color & 0xFFU) * numerator) / denominator;
    if (red > 255U) red = 255U;
    if (green > 255U) green = 255U;
    if (blue > 255U) blue = 255U;
    return (red << 16) | (green << 8) | blue;
}

static void copy_backing_rect(uint32_t x, uint32_t y, uint32_t width, uint32_t height) {
    uint32_t end_x = x + width;
    uint32_t end_y = y + height;
    if (end_x > layout.screen_width) end_x = layout.screen_width;
    if (end_y > layout.screen_height) end_y = layout.screen_height;
    for (uint32_t py = y; py < end_y; py++) {
        for (uint32_t px = x; px < end_x; px++) {
            framebuffer_put_rgb(px, py, wallpaper_backing[(size_t)py * layout.screen_width + px]);
        }
    }
}

static void calculate_layout(void) {
    /* Plain full-screen text console (VGA-text style): no floating window, no
       margins beyond a small edge gap, text fills the whole framebuffer. */
    layout.screen_width = framebuffer_width();
    layout.screen_height = framebuffer_height();
    uint32_t margin = 8U;
    layout.terminal_x = 0U;
    layout.terminal_y = 0U;
    layout.terminal_width = layout.screen_width;
    layout.terminal_height = layout.screen_height;
    layout.title_height = 0U;
    layout.content_x = margin;
    layout.content_y = margin;
    layout.cell_width = TUNIX_TERMINAL_FONT_WIDTH;
    layout.cell_height = TUNIX_TERMINAL_FONT_HEIGHT;
    uint32_t columns = (layout.screen_width - margin * 2U) / layout.cell_width;
    uint32_t rows = (layout.screen_height - margin * 2U) / layout.cell_height;
    if (columns > MAX_CONSOLE_COLS) columns = MAX_CONSOLE_COLS;
    if (rows > MAX_CONSOLE_ROWS) rows = MAX_CONSOLE_ROWS;
    if (columns < 40U) columns = 40U;
    if (rows < 16U) rows = 16U;
    layout.columns = (uint16_t)columns;
    layout.rows = (uint16_t)rows;
}

static struct console_cell *cell_at(int row, int col) {
    return &console_cells[(size_t)row * layout.columns + (size_t)col];
}

static void reset_attributes(void) {
    current_foreground = 0xD8DEE9U;
    current_background = 0x000000U;
    current_background_explicit = 0;
    current_bold = 0;
    current_reverse = 0;
}

static void clear_cell_model(void) {
    size_t count = (size_t)layout.columns * layout.rows;
    memset(console_cells, 0, count * sizeof(console_cells[0]));
}

static void clear_row_range(int row, int first_col, int last_col) {
    if (row < 0 || row >= layout.rows) return;
    if (first_col < 0) first_col = 0;
    if (last_col >= layout.columns) last_col = layout.columns - 1;
    if (first_col > last_col) return;
    memset(cell_at(row, first_col), 0,
           (size_t)(last_col - first_col + 1) * sizeof(console_cells[0]));
}

static unsigned scroll_region_up(int top, int bottom, unsigned count) {
    if (top < 0) top = 0;
    if (bottom >= layout.rows) bottom = layout.rows - 1;
    if (top > bottom) return 0;
    unsigned height = (unsigned)(bottom - top + 1);
    if (!count) count = 1;
    if (count > height) count = height;
    size_t row_bytes = (size_t)layout.columns * sizeof(console_cells[0]);
    unsigned remaining = height - count;
    if (remaining) {
        memmove(cell_at(top, 0), cell_at(top + (int)count, 0),
                (size_t)remaining * row_bytes);
    }
    memset(cell_at(bottom - (int)count + 1, 0), 0, (size_t)count * row_bytes);
    return count;
}

static unsigned scroll_region_down(int top, int bottom, unsigned count) {
    if (top < 0) top = 0;
    if (bottom >= layout.rows) bottom = layout.rows - 1;
    if (top > bottom) return 0;
    unsigned height = (unsigned)(bottom - top + 1);
    if (!count) count = 1;
    if (count > height) count = height;
    size_t row_bytes = (size_t)layout.columns * sizeof(console_cells[0]);
    unsigned remaining = height - count;
    if (remaining) {
        memmove(cell_at(top + (int)count, 0), cell_at(top, 0),
                (size_t)remaining * row_bytes);
    }
    memset(cell_at(top, 0), 0, (size_t)count * row_bytes);
    return count;
}

static void copy_cell_background(int row, int col) {
    uint32_t x = layout.content_x + (uint32_t)col * layout.cell_width;
    uint32_t y = layout.content_y + (uint32_t)row * layout.cell_height;
    copy_backing_rect(x, y, layout.cell_width, layout.cell_height);
}

static void draw_glyph_to_framebuffer(uint32_t x, uint32_t y, uint32_t codepoint,
                                      uint32_t color, int explicit_background,
                                      uint32_t background) {
    const uint8_t *glyph = tunix_terminal_font_glyph(codepoint);
    for (uint32_t row = 0; row < TUNIX_TERMINAL_FONT_HEIGHT; row++) {
        for (uint32_t column = 0; column < TUNIX_TERMINAL_FONT_WIDTH; column++) {
            uint8_t alpha = glyph[row * TUNIX_TERMINAL_FONT_WIDTH + column];
            if (!alpha) continue;
            uint32_t pixel_x = x + column;
            uint32_t pixel_y = y + row;
            uint32_t base = explicit_background
                ? background
                : wallpaper_backing[(size_t)pixel_y * layout.screen_width + pixel_x];
            framebuffer_put_rgb(pixel_x, pixel_y, blend_rgb(base, color, alpha));
        }
    }
}

static void draw_cell_overlay(int row, int col, int cursor) {
    struct console_cell *cell = cell_at(row, col);
    uint32_t x = layout.content_x + (uint32_t)col * layout.cell_width;
    uint32_t y = layout.content_y + (uint32_t)row * layout.cell_height;
    if (cell->flags & CELL_BG_EXPLICIT) {
        for (uint32_t py = 0; py < layout.cell_height; py++) {
            for (uint32_t px = 0; px < layout.cell_width; px++)
                framebuffer_put_rgb(x + px, y + py, cell->background);
        }
    }
    if (cell->codepoint >= 32U && cell->codepoint != 127U)
        draw_glyph_to_framebuffer(x, y, cell->codepoint, cell->foreground,
                                  (cell->flags & CELL_BG_EXPLICIT) != 0,
                                  cell->background);
    if (cursor) {
        uint32_t cursor_color = 0x7DCFFFU;
        for (uint32_t py = layout.cell_height - 2U; py < layout.cell_height; py++) {
            for (uint32_t px = 0; px < layout.cell_width; px++)
                framebuffer_put_rgb(x + px, y + py, cursor_color);
        }
    }
}

static void render_cell(int row, int col, int cursor) {
    if (!framebuffer_console_active()) return;
    if (row < 0 || col < 0 || row >= layout.rows || col >= layout.columns) return;
    copy_cell_background(row, col);
    draw_cell_overlay(row, col, cursor);
}

static void render_console(void) {
    if (!framebuffer_console_active()) return;
    uint32_t width = (uint32_t)layout.columns * layout.cell_width;
    uint32_t height = (uint32_t)layout.rows * layout.cell_height;
    copy_backing_rect(layout.content_x, layout.content_y, width, height);
    for (int row = 0; row < layout.rows; row++) {
        for (int col = 0; col < layout.columns; col++) {
            struct console_cell *cell = cell_at(row, col);
            if (cell->codepoint || (cell->flags & CELL_BG_EXPLICIT))
                draw_cell_overlay(row, col, 0);
        }
    }
    if (cursor_visible) draw_cell_overlay(console_row, console_col, 1);
}

static void render_region_scroll_up(int top, int bottom, unsigned count) {
    if (!framebuffer_console_active()) return;
    if (!count || top < 0 || bottom >= layout.rows || top > bottom) return;
    uint32_t x = layout.content_x;
    uint32_t y = layout.content_y + (uint32_t)top * layout.cell_height;
    uint32_t width = (uint32_t)layout.columns * layout.cell_width;
    uint32_t height = (uint32_t)(bottom - top + 1) * layout.cell_height;
    uint32_t shift = count * layout.cell_height;
    if (shift < height) {
        framebuffer_copy_rect(x, y, x, y + shift, width, height - shift);
    }
    copy_backing_rect(x, y + height - shift, width, shift);
}

static void render_region_scroll_down(int top, int bottom, unsigned count) {
    if (!framebuffer_console_active()) return;
    if (!count || top < 0 || bottom >= layout.rows || top > bottom) return;
    uint32_t x = layout.content_x;
    uint32_t y = layout.content_y + (uint32_t)top * layout.cell_height;
    uint32_t width = (uint32_t)layout.columns * layout.cell_width;
    uint32_t height = (uint32_t)(bottom - top + 1) * layout.cell_height;
    uint32_t shift = count * layout.cell_height;
    if (shift < height) {
        framebuffer_copy_rect(x, y + shift, x, y, width, height - shift);
    }
    copy_backing_rect(x, y, width, shift);
}

static void erase_visible_cursor(void) {
    if (cursor_visible) render_cell(console_row, console_col, 0);
}

static void redraw_visible_cursor(void) {
    if (cursor_visible) render_cell(console_row, console_col, 1);
}

static void clamp_terminal_cursor(void) {
    if (console_row < 0) console_row = 0;
    if (console_col < 0) console_col = 0;
    if (console_row >= layout.rows) console_row = layout.rows - 1;
    if (console_col >= layout.columns) console_col = layout.columns - 1;
}

static void terminal_scroll_if_needed(void) {
    if (console_row == scroll_bottom + 1) {
        unsigned count = scroll_region_up(scroll_top, scroll_bottom, 1);
        console_row = scroll_bottom;
        render_region_scroll_up(scroll_top, scroll_bottom, count);
    } else if (console_row >= layout.rows) {
        console_row = layout.rows - 1;
    }
}

static uint32_t xterm_256_color(unsigned index) {
    if (index < 16U) return ansi_palette[index];
    if (index < 232U) {
        unsigned value = index - 16U;
        unsigned red = value / 36U;
        unsigned green = (value / 6U) % 6U;
        unsigned blue = value % 6U;
        static const uint8_t levels[6] = {0, 95, 135, 175, 215, 255};
        return ((uint32_t)levels[red] << 16) |
               ((uint32_t)levels[green] << 8) | levels[blue];
    }
    unsigned gray = 8U + (index - 232U) * 10U;
    return (gray << 16) | (gray << 8) | gray;
}

int terminal_init(void) {
    if (!framebuffer_available()) return -1;

    calculate_layout();
    /* Plain solid-black background across the whole framebuffer; text renders on
       top and unset cell backgrounds sample from here. No wallpaper, no chrome. */
    size_t pixel_count = (size_t)layout.screen_width * layout.screen_height;
    for (size_t i = 0; i < pixel_count; i++) wallpaper_backing[i] = 0x000000U;
    copy_backing_rect(0, 0, layout.screen_width, layout.screen_height);
    clear_cell_model();
    reset_attributes();
    console_col = 0;
    console_row = 0;
    cursor_visible = 1;
    alternate_active = 0;
    scroll_top = 0;
    scroll_bottom = layout.rows - 1;
    terminal_ready = 1;
    render_cell(0, 0, 1);
    return 0;
}

void terminal_redraw(void) {
    if (!terminal_ready || !framebuffer_console_active()) return;
    render_console();
}

void terminal_clear(void) {
    if (!terminal_ready) return;
    clear_cell_model();
    console_col = 0;
    console_row = 0;
    render_console();
}

void terminal_put_codepoint(uint32_t codepoint) {
    if (!terminal_ready) return;
    if (codepoint > UINT32_C(0x10FFFF) ||
        (codepoint >= UINT32_C(0xD800) && codepoint <= UINT32_C(0xDFFF)))
        codepoint = UINT32_C(0xFFFD);

    render_cell(console_row, console_col, 0);
    if (codepoint == '\n') {
        console_col = 0;
        console_row++;
    } else if (codepoint == '\r') {
        console_col = 0;
    } else if (codepoint == '\b' || codepoint == 127U) {
        if (console_col > 0) console_col--;
        else if (console_row > 0) {
            console_row--;
            console_col = layout.columns - 1;
        }
        render_cell(console_row, console_col, 0);
    } else if (codepoint == '\t') {
        int spaces = 8 - (console_col & 7);
        while (spaces-- > 0) terminal_put_codepoint(' ');
        return;
    } else if (codepoint >= 32U) {
        struct console_cell *cell = cell_at(console_row, console_col);
        uint32_t foreground = current_foreground;
        uint32_t background = current_background;
        uint8_t explicit_background = current_background_explicit;
        if (current_reverse) {
            uint32_t temporary = foreground;
            foreground = explicit_background ? background : 0x000000U;
            background = temporary;
            explicit_background = 1;
        }
        cell->codepoint = codepoint;
        cell->foreground = current_bold ? shade_rgb(foreground, 116U, 100U) : foreground;
        cell->background = background;
        cell->flags = explicit_background ? CELL_BG_EXPLICIT : 0U;
        render_cell(console_row, console_col, 0);
        console_col++;
        if (console_col >= layout.columns) {
            console_col = 0;
            console_row++;
        }
    }
    terminal_scroll_if_needed();
    if (cursor_visible) render_cell(console_row, console_col, 1);
}

void terminal_put_char(char c) {
    terminal_put_codepoint((uint8_t)c);
}

void terminal_print(const char *text) {
    while (text && *text) terminal_put_char(*text++);
}

void terminal_set_sgr_sequence(const unsigned *codes, unsigned count) {
    if (!terminal_ready) return;
    if (!codes || !count) {
        reset_attributes();
        return;
    }

    for (unsigned i = 0; i < count; i++) {
        unsigned code = codes[i];
        if (code == 0U) reset_attributes();
        else if (code == 1U) current_bold = 1;
        else if (code == 22U) current_bold = 0;
        else if (code == 7U) current_reverse = 1;
        else if (code == 27U) current_reverse = 0;
        else if (code >= 30U && code <= 37U)
            current_foreground = ansi_palette[code - 30U];
        else if (code >= 90U && code <= 97U)
            current_foreground = ansi_palette[8U + code - 90U];
        else if (code == 39U) current_foreground = 0xD8DEE9U;
        else if (code >= 40U && code <= 47U) {
            current_background = ansi_palette[code - 40U];
            current_background_explicit = 1;
        } else if (code >= 100U && code <= 107U) {
            current_background = ansi_palette[8U + code - 100U];
            current_background_explicit = 1;
        } else if (code == 49U) {
            current_background = 0x000000U;
            current_background_explicit = 0;
        } else if ((code == 38U || code == 48U) && i + 1U < count) {
            uint32_t color = 0;
            int valid = 0;
            if (codes[i + 1U] == 5U && i + 2U < count) {
                color = xterm_256_color(codes[i + 2U] & 0xFFU);
                i += 2U;
                valid = 1;
            } else if (codes[i + 1U] == 2U && i + 4U < count) {
                if (i + 5U < count && codes[i + 2U] == 0U) {
                    color = ((codes[i + 3U] & 0xFFU) << 16) |
                            ((codes[i + 4U] & 0xFFU) << 8) |
                            (codes[i + 5U] & 0xFFU);
                    i += 5U;
                } else {
                    color = ((codes[i + 2U] & 0xFFU) << 16) |
                            ((codes[i + 3U] & 0xFFU) << 8) |
                            (codes[i + 4U] & 0xFFU);
                    i += 4U;
                }
                valid = 1;
            }
            if (valid && code == 38U) current_foreground = color;
            else if (valid) {
                current_background = color;
                current_background_explicit = 1;
            }
        }
    }
}

void terminal_set_sgr(unsigned code) {
    terminal_set_sgr_sequence(&code, 1);
}

void terminal_cursor_move(int row_delta, int col_delta) {
    if (!terminal_ready) return;
    render_cell(console_row, console_col, 0);
    console_row += row_delta;
    console_col += col_delta;
    clamp_terminal_cursor();
    if (cursor_visible) render_cell(console_row, console_col, 1);
}

void terminal_cursor_set(int row, int col) {
    if (!terminal_ready) return;
    render_cell(console_row, console_col, 0);
    console_row = row;
    console_col = col;
    clamp_terminal_cursor();
    if (cursor_visible) render_cell(console_row, console_col, 1);
}

void terminal_cursor_get(int *row, int *col) {
    if (row) *row = terminal_ready ? console_row : 0;
    if (col) *col = terminal_ready ? console_col : 0;
}

void terminal_get_dimensions(uint16_t *rows, uint16_t *cols) {
    if (rows) *rows = terminal_ready ? layout.rows : 0;
    if (cols) *cols = terminal_ready ? layout.columns : 0;
}

void terminal_set_cursor_visible(int visible) {
    visible = visible ? 1 : 0;
    if (!terminal_ready || visible == cursor_visible) return;
    render_cell(console_row, console_col, 0);
    cursor_visible = visible;
    if (cursor_visible) render_cell(console_row, console_col, 1);
}

void terminal_set_alternate_screen(int enabled) {
    enabled = enabled ? 1 : 0;
    if (!terminal_ready || enabled == alternate_active) return;
    size_t count = (size_t)layout.columns * layout.rows;
    if (enabled) {
        memcpy(primary_cells, console_cells, count * sizeof(console_cells[0]));
        primary_col = console_col;
        primary_row = console_row;
        primary_scroll_top = scroll_top;
        primary_scroll_bottom = scroll_bottom;
        clear_cell_model();
        console_col = 0;
        console_row = 0;
        scroll_top = 0;
        scroll_bottom = layout.rows - 1;
        alternate_active = 1;
    } else {
        memcpy(console_cells, primary_cells, count * sizeof(console_cells[0]));
        console_col = primary_col;
        console_row = primary_row;
        scroll_top = primary_scroll_top;
        scroll_bottom = primary_scroll_bottom;
        clamp_terminal_cursor();
        alternate_active = 0;
    }
    render_console();
}

void terminal_erase_display(unsigned mode) {
    if (!terminal_ready) return;
    if (mode == 2U || mode == 3U) {
        terminal_clear();
        return;
    }
    if (mode == 0U) {
        for (int row = console_row; row < layout.rows; row++) {
            int start = row == console_row ? console_col : 0;
            for (int col = start; col < layout.columns; col++)
                memset(cell_at(row, col), 0, sizeof(struct console_cell));
        }
    } else if (mode == 1U) {
        for (int row = 0; row <= console_row; row++) {
            int end = row == console_row ? console_col : layout.columns - 1;
            for (int col = 0; col <= end; col++)
                memset(cell_at(row, col), 0, sizeof(struct console_cell));
        }
    }
    render_console();
}

void terminal_erase_line(unsigned mode) {
    if (!terminal_ready) return;
    int start = 0;
    int end = layout.columns - 1;
    if (mode == 0U) start = console_col;
    if (mode == 1U) end = console_col;
    for (int col = start; col <= end; col++)
        memset(cell_at(console_row, col), 0, sizeof(struct console_cell));
    render_console();
}

void terminal_set_scroll_region(int top, int bottom) {
    if (!terminal_ready) return;
    if (top <= 0 && bottom <= 0) {
        scroll_top = 0;
        scroll_bottom = layout.rows - 1;
    } else {
        if (top <= 0) top = 1;
        if (bottom <= 0) bottom = layout.rows;
        top--;
        bottom--;
        if (top < 0 || bottom < 0 || top >= bottom || bottom >= layout.rows) return;
        scroll_top = top;
        scroll_bottom = bottom;
    }
    terminal_cursor_set(0, 0);
}

void terminal_insert_lines(unsigned count) {
    if (!terminal_ready || console_row < scroll_top || console_row > scroll_bottom) return;
    erase_visible_cursor();
    unsigned actual_count = scroll_region_down(console_row, scroll_bottom, count);
    render_region_scroll_down(console_row, scroll_bottom, actual_count);
    redraw_visible_cursor();
}

void terminal_delete_lines(unsigned count) {
    if (!terminal_ready || console_row < scroll_top || console_row > scroll_bottom) return;
    erase_visible_cursor();
    unsigned actual_count = scroll_region_up(console_row, scroll_bottom, count);
    render_region_scroll_up(console_row, scroll_bottom, actual_count);
    redraw_visible_cursor();
}

void terminal_insert_chars(unsigned count) {
    if (!terminal_ready) return;
    if (!count) count = 1;
    unsigned available = (unsigned)(layout.columns - console_col);
    if (count > available) count = available;
    unsigned remaining = available - count;
    if (remaining) {
        memmove(cell_at(console_row, console_col + (int)count),
                cell_at(console_row, console_col),
                (size_t)remaining * sizeof(console_cells[0]));
    }
    clear_row_range(console_row, console_col, console_col + (int)count - 1);
    render_console();
}

void terminal_delete_chars(unsigned count) {
    if (!terminal_ready) return;
    if (!count) count = 1;
    unsigned available = (unsigned)(layout.columns - console_col);
    if (count > available) count = available;
    unsigned remaining = available - count;
    if (remaining) {
        memmove(cell_at(console_row, console_col),
                cell_at(console_row, console_col + (int)count),
                (size_t)remaining * sizeof(console_cells[0]));
    }
    clear_row_range(console_row, layout.columns - (int)count, layout.columns - 1);
    render_console();
}

void terminal_erase_chars(unsigned count) {
    if (!terminal_ready) return;
    if (!count) count = 1;
    int end = console_col + (int)count - 1;
    if (end >= layout.columns) end = layout.columns - 1;
    clear_row_range(console_row, console_col, end);
    render_console();
}

void terminal_scroll_up(unsigned count) {
    if (!terminal_ready) return;
    erase_visible_cursor();
    unsigned actual_count = scroll_region_up(scroll_top, scroll_bottom, count);
    render_region_scroll_up(scroll_top, scroll_bottom, actual_count);
    redraw_visible_cursor();
}

void terminal_scroll_down(unsigned count) {
    if (!terminal_ready) return;
    erase_visible_cursor();
    unsigned actual_count = scroll_region_down(scroll_top, scroll_bottom, count);
    render_region_scroll_down(scroll_top, scroll_bottom, actual_count);
    redraw_visible_cursor();
}

void terminal_print_hex(uint32_t value) {
    char buffer[9];
    const char *digits = "0123456789ABCDEF";
    buffer[8] = '\0';
    for (int i = 7; i >= 0; i--) {
        buffer[i] = digits[value & 0x0FU];
        value >>= 4;
    }
    terminal_print(buffer);
}
