#ifndef TUNIX_COMPAT_LINUX_VT_H
#define TUNIX_COMPAT_LINUX_VT_H

/*
 * Minimal Linux VT userspace ABI required by GNU nano.
 * Tunix does not implement Linux virtual-console switching; VT_GETSTATE
 * therefore returns ENOTTY at runtime, which nano treats as "not a Linux VT".
 */
struct vt_stat {
    unsigned short v_active;
    unsigned short v_signal;
    unsigned short v_state;
};

#define VT_GETSTATE 0x5603

#endif
