#ifndef TUNIX_TTY_H
#define TUNIX_TTY_H

#include <stddef.h>
#include <stdint.h>
#include <tunix/keymap.h>

#define TCGETS      0x5401UL
#define TCSETS      0x5402UL
#define TCSETSW     0x5403UL
#define TCSETSF     0x5404UL
#define TIOCSCTTY   0x540EUL
#define TIOCNOTTY   0x5422UL
#define TIOCGPGRP   0x540FUL
#define TIOCSPGRP   0x5410UL
#define TIOCGWINSZ  0x5413UL
#define TIOCGETD    0x5424UL
#define TIOCSETD    0x5423UL

/* The console/keyboard and virtual-terminal ioctls. Tunix has exactly one
   console and no way to switch away from it, so every question about which
   terminal is active has the same answer -- but X servers and display managers
   ask before they will touch the display, and refusing is what forced the
   XORG_NO_VT and SEATD_VTBOUND=0 workarounds. */
#define KDGKBTYPE     0x4B33UL
#define KDSETMODE     0x4B3AUL
#define KDGETMODE     0x4B3BUL
#define KDGKBMODE     0x4B44UL
#define KDSKBMODE     0x4B45UL
#define VT_OPENQRY    0x5600UL
#define VT_GETMODE    0x5601UL
#define VT_SETMODE    0x5602UL
#define VT_GETSTATE   0x5603UL
#define VT_RELDISP    0x5605UL
#define VT_ACTIVATE   0x5606UL
#define VT_WAITACTIVE 0x5607UL

#define TUNIX_VT_CONSOLE 1
#define TUNIX_KB_101     0x02
#define TUNIX_KD_TEXT     0
#define TUNIX_KD_GRAPHICS 1
#define TUNIX_K_RAW       0
#define TUNIX_K_XLATE     1
#define TUNIX_K_MEDIUMRAW 2
#define TUNIX_K_UNICODE   3
#define TUNIX_K_OFF       4
#define TUNIX_VT_AUTO     0
#define TUNIX_VT_PROCESS  1

struct tunix_vt_stat {
    uint16_t v_active;
    uint16_t v_signal;
    uint16_t v_state;
};

struct tunix_vt_mode {
    uint8_t mode;
    uint8_t waitv;
    int16_t relsig;
    int16_t acqsig;
    int16_t frsig;
};

#define TTY_ISIG    0x00000001U
#define TTY_ICANON  0x00000002U
#define TTY_ECHO    0x00000008U
#define TTY_ECHOE   0x00000010U
#define TTY_ECHOK   0x00000020U
#define TTY_IEXTEN  0x00008000U

#define TTY_VINTR   0
#define TTY_VQUIT   1
#define TTY_VERASE  2
#define TTY_VKILL   3
#define TTY_VEOF    4
#define TTY_VTIME   5
#define TTY_VMIN    6
#define TTY_VSTART  8
#define TTY_VSTOP   9
#define TTY_VSUSP   10
#define TTY_NCCS    32

struct tunix_termios {
    uint32_t iflag;
    uint32_t oflag;
    uint32_t cflag;
    uint32_t lflag;
    uint8_t line;
    uint8_t cc[TTY_NCCS];
    uint32_t ispeed;
    uint32_t ospeed;
};

void tty_init(void);
int tty_ioctl(unsigned long request, void *argument);
int tty_foreground_pgid(void);
void tty_set_foreground_pgid(int pgid);
/* TIOCSCTTY: the session takes the console, and its leader takes the
   foreground. Job control is only enforced against this session. */
void tty_set_controlling_session(uint64_t sid, int pgid);
void tty_release_controlling_session(uint64_t sid);
int tty_input_ready(void);
void tty_poll_inputs(void);
void tty_handle_scancode(uint8_t scancode);
void tty_reset_keyboard_state(void);
int64_t tty_read(size_t size, void *buffer);
int64_t tty_write(size_t size, const void *buffer);

#endif
