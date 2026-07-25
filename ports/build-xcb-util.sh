#!/usr/bin/env bash
set -euo pipefail

# Build xcb-util for Tunix -- the small XCB utility library that ships four .pc
# files (xcb-util, xcb-aux, xcb-event, xcb-atom). Nothing in the weston stack
# wanted it, but startup-notification (a libwnck dependency, itself an xfwm4
# dependency) needs xcb-aux + xcb-event, so it enters with the X11/Xfce work.
#
# A single cross *autotools* lib on top of libxcb (the build-libxcb.sh pattern):
# autoreconf on a copy so ports/src stays clean, cross-configure, install to the
# sysroot and the image root. xcb-util keeps its autoconf macros in a nested `m4`
# submodule (XCB_UTIL_COMMON), so that must be checked out first.
#
# Payload: libxcb-util.so.1 -> sysroot + image; headers/.pc -> sysroot only.

PORT_NAME=xcb-util
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xcb-util"
BUILD="$OUT/xcb-util-build"
ROOT_DIR="$OUT/xcb-util-root"

cross_port_require_toolchain
cross_port_require_tools pkg-config autoreconf gcc "$READELF"
[[ -f "$SOURCE/configure.ac" ]] || cross_port_fail \
    "missing $SOURCE; run git submodule update --init"
[[ -f "$SOURCE/m4/xcb_util_common.m4" ]] || cross_port_fail \
    "xcb-util's m4 submodule is missing; run git -C $SOURCE submodule update --init"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/xcb.pc" ]] || cross_port_fail \
    "libxcb is not in the sysroot; build it first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_autotools_setup

# Copy out of ports/src (no .git) so autoreconf can write into the tree.
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD" -xf -

( cd "$BUILD" && NOCONFIGURE=1 autoreconf -fi >/dev/null )
( cd "$BUILD" && ./configure --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
    --prefix=/usr --disable-static --enable-shared )
make -C "$BUILD" -j "$JOBS"
make -C "$BUILD" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD" DESTDIR="$ROOT_DIR" install

# Drop the staged .la so a later cross libtool link resolves through the .pc
# files rather than following libdir=/usr/lib to the host (the libxcb trap).
find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

for pc in xcb-util xcb-aux xcb-event xcb-atom; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc.pc was not installed into the sysroot"
done

lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libxcb-util.so.1*' -print -quit)
[[ -n "$lib" ]] || cross_port_fail "libxcb-util.so.1 was not installed"
cross_port_check_library "$lib" libxcb-util.so.1

# Image keeps the shared library only.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libxcb-util links only libxcb (from xcb-root) and the musl runtime.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/xcb-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xcb-util (xcb-util/aux/event/atom) staged at %s (%s)\n' "$ROOT_DIR" "$size"
