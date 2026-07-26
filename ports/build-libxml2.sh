#!/usr/bin/env bash
set -euo pipefail

# Build libxml2 for Tunix -- the GNOME XML library. Only one consumer wants it:
# libxkbcommon's libxkbregistry (the keyboard-layout registry), which xfce4-
# settings' keyboard dialog and xfsettingsd link. So libxml2 is built minimal
# (no python, http, icu, readline, docs) -- just the parser xkbregistry needs,
# on zlib from the cairo chain.
#
# Output: libxml2.so.2 + headers/.pc to the graphics sysroot; the .so to the
# image root (libxkbregistry loads it).

PORT_NAME=libxml2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libxml2"
BUILD="$OUT/libxml2-build"
ROOT_DIR="$OUT/libxml2-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config "$READELF"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/zlib.pc" ]] || cross_port_fail \
    "zlib is not in the sysroot; build the cairo chain first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dzlib=enabled \
    -Dpython=disabled \
    -Dhttp=disabled \
    -Dicu=disabled \
    -Dreadline=disabled \
    -Ddocs=disabled \
    -Dtls=disabled
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libxml-2.0.pc" ]] || \
    cross_port_fail "libxml-2.0.pc was not installed into the sysroot"

lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libxml2.so.16*' -print -quit)
[[ -n "$lib" ]] || cross_port_fail "libxml2.so.16 was not installed"
cross_port_check_library "$lib" libxml2.so.16

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libxml2 links zlib (cairo-root ships libz) and the musl runtime.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/cairo-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libxml2 staged at %s (%s)\n' "$ROOT_DIR" "$size"
