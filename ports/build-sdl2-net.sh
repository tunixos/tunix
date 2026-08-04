#!/usr/bin/env bash
set -euo pipefail

# SDL2_net for Tunix. Small, but chocolate-doom links it unconditionally even
# for a single-player build, so it is not optional.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + SDL2_net.pc
#   $OUT/sdl2-net-root/usr/lib                libSDL2_net-2.0.so.0 for the image

PORT_NAME=SDL2_net
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/SDL2_net"
BUILD="$OUT/sdl2-net-build"
ROOT_DIR="$OUT/sdl2-net-root"

EXPECTED_VERSION=2.2.0

[[ -f "$SOURCE/configure" ]] || cross_port_fail \
    "missing SDL2_net source at $SOURCE; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools pkg-config gcc "$READELF"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/sdl2.pc" ]] || \
    cross_port_fail "sdl2.pc is not in the sysroot; build the SDL2 port first"

version=$(sed -n 's/^#define SDL_NET_\(MAJOR_VERSION\|MINOR_VERSION\|PATCHLEVEL\) *//p' \
    "$SOURCE/SDL_net.h" | paste -sd. -)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected SDL2_net $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/src" "$BUILD/obj" "$ROOT_DIR"

# A copy, so the shipped autotools output can be touched newer than its inputs
# without writing to ports/src. Otherwise make reruns aclocal, which is not here.
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/src" -xf -
( cd "$BUILD/src" && sh touch-autofoo.sh )

cross_port_autotools_setup

cross_port_configure "$BUILD/src" "$BUILD/obj" \
    --libdir=/usr/lib \
    --disable-sdltest \
    --disable-rpath

make -C "$BUILD/obj" -j "$JOBS"
make -C "$BUILD/obj" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD/obj" DESTDIR="$ROOT_DIR" install

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/include/SDL2/SDL_net.h" ]] || \
    cross_port_fail "SDL_net.h was not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/SDL2_net.pc" ]] || \
    cross_port_fail "SDL2_net.pc was not installed into the graphics sysroot"

shared=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libSDL2_net-2.0.so.0*' -print -quit)
[[ -n "$shared" ]] || cross_port_fail "libSDL2_net was not installed"
cross_port_check_library "$shared" libSDL2_net-2.0.so.0

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/aclocal"
find "$ROOT_DIR/usr/lib" \( -name '*.la' -o -name '*.a' \) -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/sdl2-root" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root" \
    "$OUT/alsa-lib-root" "$OUT/libudev-zero-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'SDL2_net %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
