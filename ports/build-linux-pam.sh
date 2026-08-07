#!/usr/bin/env bash
set -euo pipefail

# Build Linux-PAM for Tunix -- the pluggable authentication stack.
#
# Tunix has had real accounts since shadow was ported, but every program that
# authenticates reads /etc/shadow its own way: login, su and sudo each carry
# their own copy of the logic and there is no single place to say what "logging
# in" means. PAM is that place, and it is also a hard requirement of LightDM,
# which has no non-PAM authentication path at all.
#
# The modules are dlopen'd from /usr/lib/security, so this is a shared-library
# port on the musl cross toolchain rather than one of the static musl-gcc ones.
#
# musl notes: NIS, libeconf, SELinux, audit and Berkeley DB have nothing behind
# them here; --disable-nis in particular is what keeps rpcsvc/ypclnt.h out.
# pam_unix verifies with crypt(3), which musl implements including SHA-512, so
# it reads the same /etc/shadow hashes shadow-utils writes.

PORT_NAME=linux-pam
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/linux-pam"
ROOT_DIR="$OUT/linux-pam-root"

EXPECTED_VERSION=1.6.1
version=$(sed -n 's/^AC_INIT(\[Linux-PAM\],\[\([^]]*\)\].*/\1/p' "$SOURCE/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected Linux-PAM $EXPECTED_VERSION, found ${version:-unknown}"

cross_port_require_toolchain
cross_port_require_tools autoreconf autopoint libtoolize pkg-config "$READELF"

# Bootstrap and build from a copy on a case-sensitive filesystem.
#
# Only configure.ac is tracked, so autoreconf has to run -- and PAM's top-level
# Makefile.am pins `AUTOMAKE_OPTIONS = ... gnu ...`, which requires a ChangeLog
# and outranks anything the command line can say. Upstream satisfies that by
# touching one next to the tracked CHANGELOG; on the Windows drive this working
# copy lives on those are the same file, and automake reads the directory
# listing itself, so the requirement can never be met in place.
#
# WORK defaults inside WSL rather than under ports/out for the same reason.
WORK=${LINUX_PAM_WORK:-/var/tmp/tunix-linux-pam}
[[ "$WORK" != /mnt/* ]] || cross_port_fail \
    "LINUX_PAM_WORK must be on a case-sensitive filesystem, not $WORK"

rm -rf "$WORK" "$ROOT_DIR"
mkdir -p "$WORK" "$ROOT_DIR"
cp -a "$SOURCE/." "$WORK/"
BUILD="$WORK/build"
mkdir -p "$BUILD"

( cd "$WORK" && ./autogen.sh ) || cross_port_fail "autogen.sh failed"

cross_port_autotools_setup

# --enable-isadir is a path *relative to securedir*: PAM tries it first for a
# multilib module and only then falls back. Pointing it at securedir itself
# means the fallback and the first try are the same directory.
cross_port_configure "$WORK" "$BUILD" \
    --libdir=/usr/lib \
    --sbindir=/usr/sbin \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --disable-nls \
    --disable-doc \
    --disable-examples \
    --disable-nis \
    --disable-selinux \
    --disable-audit \
    --disable-econf \
    --disable-openssl \
    --enable-db=no \
    --enable-securedir=/usr/lib/security \
    --enable-isadir=. \
    --enable-sconfigdir=/etc/security

make -C "$BUILD" -j"$JOBS"
# Twice: the image root is what ships, the graphics sysroot is what LightDM --
# and anything else that authenticates -- compiles and links against.
make -C "$BUILD" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
find "$GRAPHICS_SYSROOT/usr/lib" -maxdepth 2 -name 'libpam*.la' -delete
make -C "$BUILD" install DESTDIR="$ROOT_DIR"

[[ -f "$ROOT_DIR/usr/lib/libpam.so.0.85.1" ]] || cross_port_fail "libpam was not built"
# The three modules a login actually walks through. pam_unix is the one that
# reads /etc/shadow; without it PAM is an empty policy engine.
for module in pam_unix pam_permit pam_deny pam_env pam_nologin pam_limits; do
    [[ -f "$ROOT_DIR/usr/lib/security/$module.so" ]] || \
        cross_port_fail "$module.so was not built"
done

# PAM ships no /etc/pam.d of its own -- the policy is the distribution's to
# write, and Tunix's lives in initrd/etc/pam.d.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/systemd" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/locale" "$ROOT_DIR/etc/pam.d"
find "$ROOT_DIR" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -name '*.a' -delete 2>/dev/null || true

# The modules are dlopen'd rather than linked, so the closure check below never
# reaches them from an executable. Assert the important one resolves on its own.
cross_port_check_library "$ROOT_DIR/usr/lib/libpam.so.0.85.1" libpam.so.0

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'Linux-PAM staged at %s (%s)\n' "$ROOT_DIR" "$size"
