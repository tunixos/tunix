#!/usr/bin/env bash
set -euo pipefail

# Build pixman for Tunix.
#
# pixman is the pixel-manipulation library Weston's software renderer is built
# on. It is the piece that makes a first Weston bring-up possible without any
# GPU or GL at all -- weston's pixman renderer composites on the CPU, so the
# graphics hardware question can be deferred entirely.
#
# It has no mandatory dependencies of its own; libpng and gtk are only used by
# the test and demo programs, which we do not build.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for weston later
#   $OUT/pixman-root/usr/lib                  shared library staged for the image

PORT_NAME=pixman
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/pixman"
BUILD="$OUT/pixman-build"
ROOT_DIR="$OUT/pixman-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_VERSION=0.46.4

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing pixman source at $SOURCE; run git submodule update --init --recursive"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config "$READELF"

version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected pixman $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

# SSE2 and SSSE3 are baseline on x86_64 and are pixman's fast paths, so they
# stay on; everything below composites in C otherwise, which on softpipe-era
# performance would be felt immediately.
meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    -Dtests=disabled \
    -Ddemos=disabled \
    -Dgtk=disabled \
    -Dlibpng=disabled \
    -Dopenmp=disabled

meson compile -C "$BUILD" -j "$JOBS"

DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -f "$GRAPHICS_SYSROOT/usr/include/pixman-1/pixman.h" ]] || \
    cross_port_fail "pixman headers were not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/pixman-1.pc" ]] || \
    cross_port_fail "pixman-1.pc was not installed into the graphics sysroot"

shared=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libpixman-1.so.0*' -print -quit)
[[ -n "$shared" ]] || cross_port_fail "pixman shared library was not installed"
cross_port_check_library "$shared" libpixman-1.so.0

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR"

printf 'pixman %s staged at %s\n' "$version" "$ROOT_DIR"
