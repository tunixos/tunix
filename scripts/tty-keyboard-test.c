#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Include the implementation so this regression test can inspect its private
 * input queue without exposing test-only kernel APIs. */
#include "../src/kernel/tty.c"

static void fail(const char *name, int expected, int actual) {
    fprintf(stderr, "%s: expected 0x%02x, got 0x%02x\n", name, expected, actual);
    exit(1);
}

static void expect_byte(const char *name, int expected) {
    int actual = input_pop();
    if (actual != expected) fail(name, expected, actual);
}

static void expect_empty(const char *name) {
    int actual = input_pop();
    if (actual != -1) fail(name, -1, actual);
}

static void press_ctrl(uint8_t key) {
    tty_handle_scancode(0x1d);
    tty_handle_scancode(key);
    tty_handle_scancode(0x9d);
}

static void test_nano_shortcuts(void) {
    tty_init();
    press_ctrl(0x2d); /* Ctrl+X */
    press_ctrl(0x18); /* Ctrl+O */
    press_ctrl(0x11); /* Ctrl+W */
    expect_byte("Ctrl+X", 0x18);
    expect_byte("Ctrl+O", 0x0f);
    expect_byte("Ctrl+W", 0x17);
    expect_empty("Nano shortcut queue");
}

static void test_meta_and_navigation(void) {
    tty_init();

    tty_handle_scancode(0x38); /* Alt down */
    tty_handle_scancode(0x11); /* W */
    tty_handle_scancode(0xb8); /* Alt up */
    expect_byte("Alt prefix", 0x1b);
    expect_byte("Alt+W", 'w');

    tty_handle_scancode(0x0e);
    expect_byte("Backspace", 0x7f);

    tty_handle_scancode(0x2a);
    tty_handle_scancode(0x0f);
    tty_handle_scancode(0xaa);
    expect_byte("Shift-Tab ESC", 0x1b);
    expect_byte("Shift-Tab [", '[');
    expect_byte("Shift-Tab Z", 'Z');

    tty_handle_scancode(0xe0);
    tty_handle_scancode(0x48);
    expect_byte("Up ESC", 0x1b);
    expect_byte("Up [", '[');
    expect_byte("Up A", 'A');

    tty_handle_scancode(0x3b);
    expect_byte("F1 ESC", 0x1b);
    expect_byte("F1 O", 'O');
    expect_byte("F1 P", 'P');

    tty_handle_scancode(0x58);
    expect_byte("F12 ESC", 0x1b);
    expect_byte("F12 [", '[');
    expect_byte("F12 2", '2');
    expect_byte("F12 4", '4');
    expect_byte("F12 ~", '~');
    expect_empty("Navigation queue");
}

static void test_raw_termios_is_preserved(void) {
    struct tunix_termios settings;
    struct tunix_termios actual;

    tty_init();
    if (tty_ioctl(TCGETS, &settings) != 0) exit(1);
    settings.lflag &= ~(TTY_ECHO | TTY_ICANON | TTY_ISIG);
    if (tty_ioctl(TCSETS, &settings) != 0) exit(1);
    if (tty_ioctl(TCGETS, &actual) != 0) exit(1);
    if (actual.lflag != settings.lflag) {
        fprintf(stderr, "TCSETS changed lflag: expected 0x%x, got 0x%x\n",
                settings.lflag, actual.lflag);
        exit(1);
    }
}

int main(void) {
    test_nano_shortcuts();
    test_meta_and_navigation();
    test_raw_termios_is_preserved();
    puts("tty keyboard/raw-mode regression: PASS");
    return 0;
}

/* Kernel dependencies not exercised by this host-side keyboard test. */
void serial_write_char(char c) { (void)c; }
void input_poll(void) {}
int process_send_signal(int64_t pid, int signal_number) {
    (void)pid;
    (void)signal_number;
    return 0;
}
void terminal_clear(void) {}
void terminal_put_char(char c) { (void)c; }
void terminal_set_sgr(unsigned code) { (void)code; }
void terminal_set_sgr_sequence(const unsigned *codes, unsigned count) {
    (void)codes;
    (void)count;
}
void terminal_cursor_move(int row_delta, int col_delta) {
    (void)row_delta;
    (void)col_delta;
}
void terminal_cursor_set(int row, int col) { (void)row; (void)col; }
void terminal_cursor_get(int *row, int *col) {
    if (row) *row = 0;
    if (col) *col = 0;
}
void terminal_set_cursor_visible(int visible) { (void)visible; }
void terminal_set_alternate_screen(int enabled) { (void)enabled; }
void terminal_erase_display(unsigned mode) { (void)mode; }
void terminal_erase_line(unsigned mode) { (void)mode; }
void terminal_set_scroll_region(int top, int bottom) { (void)top; (void)bottom; }
void terminal_insert_lines(unsigned count) { (void)count; }
void terminal_delete_lines(unsigned count) { (void)count; }
void terminal_insert_chars(unsigned count) { (void)count; }
void terminal_delete_chars(unsigned count) { (void)count; }
void terminal_erase_chars(unsigned count) { (void)count; }
void terminal_scroll_up(unsigned count) { (void)count; }
void terminal_scroll_down(unsigned count) { (void)count; }
