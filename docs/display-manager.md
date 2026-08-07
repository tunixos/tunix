# Display Manager

Tunix boots to a graphical login. LightDM starts the X server, runs a greeter
on it, checks the password through PAM, and replaces the greeter with the
user's desktop. This describes the pieces and the two places the machine is
unusual enough that a stock display manager needed help.

## The shape of it

```
dinit (PID 1)
├── dbus-daemon --system             the system bus
└── lightdm                          root, /usr/sbin/lightdm
    ├── Xorg                         via /etc/lightdm/Xserver
    ├── lightdm-gtk-greeter          user lightdm, via /etc/lightdm/Xsession
    └── tunix-desktop                the user, via /etc/lightdm/Xsession
```

The system bus is new. Tunix ran D-Bus only inside a session — `tunix-desktop`
starts its own — and nothing had ever needed a bus that outlives one login.
LightDM publishes `org.freedesktop.DisplayManager` on the system bus and
**exits** if it cannot own the name, so `dbus` is a hard dependency of the
`lightdm` service rather than an optional extra.

The greeter has no privileges. It collects a username and a password and hands
them to the daemon over a socket; the daemon is the only thing that ever opens
`/etc/shadow`. That split is why the login screen can be an ordinary GTK3 X
client and why `/etc/pam.d/lightdm-greeter` authenticates nobody.

## Authentication

Linux-PAM is the new piece underneath. Before it, `login`, `su` and `sudo` each
carried their own copy of "read `/etc/shadow`, verify the hash", and there was
no single place to say what logging in means. Now there is, in `/etc/pam.d`:

| File | Used by |
| --- | --- |
| `system-auth` | the shared policy; the others include it |
| `lightdm` | a password login at the greeter |
| `lightdm-greeter` | the greeter's own session — no authentication |
| `lightdm-autologin` | autologin, if `lightdm.conf` names an account |
| `other` | anything with no file of its own: `pam_warn` then `pam_deny` |

`pam_unix` does the deciding. It verifies the SHA-512 `crypt(3)` hash that
shadow-utils writes and musl implements, so the accounts are exactly the
accounts that already existed. Nothing about `/etc/passwd` or `/etc/shadow`
changed.

`login`, `su` and `sudo` still do not go through PAM. They were built without
it and they keep working as they did; moving them across is a separate job.

## Virtual terminals

A display manager's first question is which terminal to put the X server on.
Tunix has one console and no way to switch away from it, so the kernel answers
every form of that question the same way. `src/kernel/tty.c` handles:

| ioctl | Answer |
| --- | --- |
| `VT_OPENQRY` | 1 — the console, the only terminal there is |
| `VT_GETSTATE` | active 1, no pending signal |
| `VT_ACTIVATE`, `VT_WAITACTIVE` | success for 1, `EINVAL` for anything else |
| `VT_GETMODE`, `VT_SETMODE` | `VT_AUTO`; a registered signal can never fire |
| `VT_RELDISP` | success |
| `KDGETMODE`, `KDSETMODE` | remembered, and it does something — see below |
| `KDGKBMODE`, `KDSKBMODE` | remembered |
| `KDGKBTYPE` | `KB_101` |

They are asked on `/dev/tty0`, which is a symlink to `/dev/console`.

`KDSETMODE` is the one with a side effect. `KD_GRAPHICS` is a program saying it
will paint the screen itself, so the text console stands down and hands over the
scanout — the same arbitration DRM already performs when a client presents its
first frame. `KD_TEXT` gives it back and the console redraws.

LightDM does use these. It claims a terminal for the seat before it starts
anything — the first free one at or above `minimum-vt` — and then `VT_ACTIVATE`s
it and reads `VT_GETSTATE` back. Upstream's default of 7 names a terminal that
does not exist here, so `lightdm.conf` sets `minimum-vt=1`: the console, the one
the kernel answers for.

Whether *Xorg* binds a console is a separate question, answered by
`XORG_NO_VT` in the server wrapper. The façade is also what retires the reason
`startx` sets `SEATD_VTBOUND=0`.

## The two wrappers

`/etc/lightdm/Xserver` and `/etc/lightdm/Xsession` exist because neither of the
things they set is expressible in `lightdm.conf`.

The server wrapper exports `XORG_NO_VT`, which the Xorg port reads to skip the
`/dev/tty0` probe and the VT ioctls entirely — input comes from evdev and the
display from DRM master, neither of which needs a console. It also names
`/etc/X11/xorg.conf` outright and drops any `vtN` argument.

The session wrapper sets the XDG environment. LightDM's children are not started
by a shell, so they inherit neither `/etc/profile` nor anything `tunix-session`
exports for itself.

## The session

`/bin/tunix-desktop` is the desktop: the session bus, `xfsettingsd`, `xfwm4`,
the panel, `xfdesktop`, the wallpaper. It blocks on the window manager, so when
`xfwm4` goes the session is over and the greeter comes back.

`/bin/tunix-session` is the console route to the same thing — it starts Xorg
itself and then calls `tunix-desktop`. Both exist so there is one definition of
what the desktop is, whichever way you arrive at it.
`/usr/share/xsessions/tunix.desktop` is how LightDM finds it.

## Going back to the console login

The `login` service is still defined; only what `boot` waits for changed. The
two cannot both run — there is one screen and one keyboard — so it is a swap:

```
# dinitctl stop lightdm
# dinitctl start login
```

## What it took

Nothing above worked on the first boot, and none of the five things that had to
be fixed were about display management. They are recorded here because each one
is a gap that any threaded, privilege-dropping program would have hit.

**1. There was no system bus.** D-Bus only ever ran inside a session. LightDM
publishes `org.freedesktop.DisplayManager` on the system bus and `exit(1)`s if
it cannot own the name, so it died four times with nothing on the console but
"exit code 1".

**2. `siginfo` never said who sent a signal.** The X server reports itself ready
by raising `SIGUSR1`; LightDM reads `si_pid` and looks the sender up to decide
*which* server it was. The kernel filled in `si_signo` and `si_code` and left
`si_pid` zero, so the lookup missed and LightDM waited forever for a signal it
had already received. Pending signals are a bitmask rather than a queue, so one
sender per signal is exactly the right granularity to record.

**3. The signal range stopped at 32.** musl reserves 32, 33 and 34 for itself,
and implements `setuid`/`setgid` in a threaded process by sending signal 34 to
every other thread so they all change identity together. `tkill` refused it,
`__synccall` nopped out the callback, and `__setxid` returned `EAGAIN` **without
having tried** — which is how the greeter died on an assertion in a function
that does nothing but call `setresgid` and `setresuid`.

**4. Threads had private copies of the handler table.** Fixing (3) turned the
silent `EAGAIN` into a kill: `__synccall` installs its handler in the calling
thread and signals the siblings, and a sibling still holding `SIG_DFL` for a
real-time signal takes the whole process down. `CLONE_SIGHAND` is mandatory for
a thread here, so `sigaction` now writes through to the group.

**5. Pipe ends did not record their direction.** `g_io_channel_unix_new()` asks
`fcntl(F_GETFL)` which way a descriptor goes. Both ends of every pipe read back
`O_RDONLY`, so GLib decided the greeter's write channel was not writable and
refused every write to it.

And one that was not a kernel bug: `pam_limits` calls `getpriority`, treats a
failure as fatal, and Tunix did not implement it. It does now — returning
`20 - nice`, because the syscall reports it that way so a negative nice is not
mistaken for an error.

Two configuration choices worth knowing:

`lock-memory=false`. LightDM routes passwords through libgcrypt's secure pool
by default, but it never initialises libgcrypt and never checks what the
allocator returns — so a pool that does not come up is a `memcpy` to a null
pointer. Tunix has no `mlock` and no swap, so a "locked" pool would be locking
nothing anyway.

The session entry is `tunix.desktop`, not `xfce.desktop`. xfce4-session
installs one of the latter with `Exec=startxfce4`, and the port roots are copied
over the initrd — sharing the name means whichever lands last wins.

## What is not here

`logind`, ConsoleKit and accounts-service are not ported, so LightDM runs
without a session-tracking daemon: `loginctl`-style session objects, seat
switching and the guest session do not exist. On a single-seat machine none of
them has anything to do.

The keyboard-layout menu in the greeter is empty. It comes from libxklavier,
which is patched out; Tunix has one layout, set in `/etc/vconsole.conf`.

Suspend, hibernate and power-off from the greeter need polkit and a power
daemon. Neither is ported, so the buttons are absent.
