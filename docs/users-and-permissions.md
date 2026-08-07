# Users and Permissions

Tunix used to have exactly one identity. Every process was root, `getuid()`
answered 0 because there was nothing else it could answer, and the only thing a
path check asked was whether the file existed. This describes what replaced it.

## Accounts

The image ships two people and the usual system accounts:

| Account | uid | Password | Home |
| --- | --- | --- | --- |
| `root` | 0 | `root` | `/root` |
| `tunix` | 1000 | `tunix` | `/home/tunix` |

`tunix` is in `wheel` (so `sudo` works), and in `audio`, `video` and `input`,
which is how an unprivileged desktop reaches the sound card, the display and the
keyboard. The groups are not decoration: the device nodes carry them.

| Device | Group |
| --- | --- |
| `/dev/dri/card0`, `/dev/fb0` | `video` (44) |
| `/dev/input/event*` | `input` (45) |
| `/dev/snd/*` | `audio` (29) |
| `/dev/pts/*` | `tty` (5) |
| `/dev/sda` | `disk` (6) |

## Logging in

dinit starts LightDM, which asks for the password at a graphical greeter and
checks it through PAM -- see [Display Manager](display-manager.md). The
`login` service is still defined for a console login and does the same thing
without a screen: shadow's `login(1)` checks `/etc/shadow` directly, sets the
account's groups, gid and uid, and execs the login shell.

Either way the desktop runs as whoever logged in rather than as root. Everything
it once needed root for -- the runtime directory, the machine id, the compiled
GSettings schemas -- happens earlier in `/etc/rc.d/rcS`, which is still root.

`login`, `su` and `sudo` do not go through PAM: they were built without it and
each still reads `/etc/shadow` its own way. Only LightDM authenticates through
`/etc/pam.d`.

## Becoming somebody else

`su`, `sudo` and `passwd` are the real programs, ported from shadow-utils and
sudo. They work because the kernel honours the set-user-ID bit: the binaries are
installed 4755, so an exec of them runs with euid 0 while the real uid stays the
caller's, and dropping back is what the saved uid is for.

```
$ id
uid=1000(tunix) gid=1000(tunix) groups=1000(tunix),4(adm),10(wheel),29(audio),44(video),45(input),100(users)
$ sudo id -u
[sudo] password for tunix:
0
$ su -
Password:
# whoami
root
```

`/etc/sudoers` gives `%wheel` full access. `visudo` edits it safely.

## What the kernel enforces

Credentials live on the process: real, effective and saved uid/gid, the
filesystem uid/gid, and up to 32 supplementary groups. They are inherited across
`fork()` and `clone()`, and an `execve()` of a setuid binary is the only way to
gain one you did not have.

Checked against the mode bits, with root overriding everything except execute
permission on a file that has no execute bit at all:

- `open()` -- read/write on the file, plus write and search on the directory
  when creating.
- `execve()` -- execute on the program and search on every directory leading to
  it. A script's interpreter is checked too; scripts never get setuid.
- `mkdir`, `rmdir`, `unlink`, `rename`, `symlink` -- write and search on the
  parent, and the sticky-bit rule in `/tmp`: only the owner may remove.
- `chdir` -- search.
- `chmod` -- owner or root. `chown` -- root, except that an owner may hand a
  file to one of their own groups; either way the setuid bits come off.
- `access()`/`faccessat()` -- the real ids, or the effective ones with
  `AT_EACCESS`.
- `kill()` -- the target must share the sender's identity, or the sender is root.

A new file is owned by whoever created it, with the group taken from the parent
directory when that directory is setgid.

The console has a session now, rather than a single global foreground process
group: `TIOCSCTTY` claims it, `TIOCNOTTY` gives it up, and the job-control rule
that stops a background process from reading the terminal only applies inside
the session that holds it. Without that, `login` was refused its own first read.
`/proc/self` and `/proc/<pid>/fd` exist for the same practical reason: that is
how `ttyname(3)` answers, and `su` will not run for a non-root caller whose
terminal it cannot name.

## How the image gets its permissions

The rootfs is staged on a Windows drive, which reports every file as 0777
root:root, so the modes cannot come from the staging tree. `make` runs
`scripts/apply-permissions.py` over the finished archive instead: programs (ELF
or `#!`) become 0755, data 0644, directories 0755, and
`scripts/rootfs-permissions.conf` lists the exceptions -- `/etc/shadow` at 0600,
the setuid binaries at 4755, `/tmp` sticky, `/home/tunix` owned by uid 1000.

That file is the place to add a permission, not the Makefile: a `chmod` in the
build is a no-op on that filesystem.
