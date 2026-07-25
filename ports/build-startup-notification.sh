#!/usr/bin/env bash
set -euo pipefail

# Build startup-notification for Tunix -- the freedesktop launch-feedback library
# (the "busy" pointer while an app starts). libwnck's tasklist links it
# unconditionally, and libwnck is a hard xfwm4 dependency, so it has to be here
# before the Xfce window manager. xfce4-panel later wants it too.
#
# A cross autotools lib (the build-xcb-util.sh pattern) on top of libxcb +
# xcb-util (xcb-aux/xcb-event) + x11-xcb. autoreconf on a copy so ports/src stays
# clean, cross-configure, install to the sysroot and the image root.
#
# Payload: libstartup-notification-1.so.0 -> sysroot + image; headers/.pc -> sysroot.

PORT_NAME=startup-notification
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/startup-notification"
BUILD="$OUT/startup-notification-build"
ROOT_DIR="$OUT/startup-notification-root"

cross_port_require_toolchain
cross_port_require_tools pkg-config autoreconf gcc "$READELF"
[[ -f "$SOURCE/configure.in" || -f "$SOURCE/configure.ac" ]] || cross_port_fail \
    "missing $SOURCE; run git submodule update --init"
for pc in xcb-aux xcb-event x11-xcb; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc is not in the sysroot; build xcb-util (and libxcb) first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_autotools_setup

tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD" -xf -

# lt~obsolete etc.: startup-notification predates modern libtool, so let
# autoreconf regenerate everything (-f) and add missing aux files (-i).
( cd "$BUILD" && NOCONFIGURE=1 autoreconf -fi >/dev/null 2>&1 )
# startup-notification's configure has an AC_TRY_RUN probe for a sane realloc()
# (lf_cv_sane_realloc) that cannot execute under cross-compilation; preseed the
# cache with musl's answer -- realloc(0,n) is malloc(n) and returns non-null.
( cd "$BUILD" && \
    lf_cv_sane_realloc=yes \
    ./configure --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
    --prefix=/usr --disable-static --enable-shared )
make -C "$BUILD" -j "$JOBS"
make -C "$BUILD" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD" DESTDIR="$ROOT_DIR" install

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libstartup-notification-1.0.pc" ]] || \
    cross_port_fail "libstartup-notification-1.0.pc was not installed into the sysroot"

lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f \
    -name 'libstartup-notification-1.so.0*' -print -quit)
[[ -n "$lib" ]] || cross_port_fail "libstartup-notification-1.so.0 was not installed"
cross_port_check_library "$lib" libstartup-notification-1.so.0

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# NEEDED: libxcb (xcb-root), libxcb-util (xcb-util-root), libX11/libX11-xcb
# (libX11-root) and the musl runtime.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/xcb-root" "$OUT/xcb-util-root" \
    "$OUT/libX11-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'startup-notification staged at %s (%s)\n' "$ROOT_DIR" "$size"
