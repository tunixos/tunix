#!/usr/bin/env bash
set -euo pipefail

# Build libxkbcommon for Tunix.
#
# Weston links this unconditionally: it is what turns evdev keycodes into
# keysyms, and libweston's input core will not build without it. Nothing about
# it needs a display, so it is on the path to the headless bring-up.
#
# Built without X11 (no xcb), without the tools, and without libxkbregistry,
# which parses the rules XML and would pull in libxml2.
#
# Runtime data: compiling a keymap from *names* (the usual evdev/pc105/us) reads
# the xkeyboard-config database under $XKB_CONFIG_ROOT. That database is a
# separate project and is not built here, so the check at the end reports
# whether it is present rather than assuming it -- a keymap built from an
# explicit string works either way, and that is what proves the library itself.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for weston later
#   $OUT/libxkbcommon-root/usr/lib            shared library staged for the image

PORT_NAME=libxkbcommon
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libxkbcommon"
BUILD="$OUT/libxkbcommon-build"
ROOT_DIR="$OUT/libxkbcommon-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"
TEST_SOURCE="$ROOT/tools/xkb-test.c"

EXPECTED_VERSION=1.13.0
# Where the xkeyboard-config database is expected on Tunix, matching where
# every Linux distribution puts it.
XKB_CONFIG_ROOT=/usr/share/X11/xkb

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing libxkbcommon source at $SOURCE; run git submodule update --init --recursive"
[[ -f "$TEST_SOURCE" ]] || cross_port_fail "missing the xkb test at $TEST_SOURCE"

cross_port_require_toolchain
# bison generates the keymap-text parser; libxkbcommon requires >= 3.6.
cross_port_require_tools meson ninja pkg-config bison "$READELF"

version=$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected libxkbcommon $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr \
    --libdir=lib \
    --buildtype=release \
    --default-library=shared \
    -Denable-x11=false \
    -Denable-wayland=false \
    -Denable-tools=false \
    -Denable-docs=false \
    -Denable-xkbregistry=false \
    -Dxkb-config-root="$XKB_CONFIG_ROOT"

meson compile -C "$BUILD" -j "$JOBS"

DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -f "$GRAPHICS_SYSROOT/usr/include/xkbcommon/xkbcommon.h" ]] || \
    cross_port_fail "xkbcommon headers were not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/xkbcommon.pc" ]] || \
    cross_port_fail "xkbcommon.pc was not installed into the graphics sysroot"

shared=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libxkbcommon.so.0*' -print -quit)
[[ -n "$shared" ]] || cross_port_fail "libxkbcommon shared library was not installed"
cross_port_check_library "$shared" libxkbcommon.so.0

# Compile a keymap on the build host using the library we just cross-built, to
# prove the parser and the keysym tables actually work rather than merely link.
mkdir -p "$ROOT_DIR/usr/bin"
"$CROSS_CC" -std=c11 -Wall -Wextra -O2 -fPIE -pie \
    -I"$GRAPHICS_SYSROOT/usr/include" \
    "$TEST_SOURCE" \
    -L"$GRAPHICS_SYSROOT/usr/lib" \
    -Wl,-rpath-link,"$GRAPHICS_SYSROOT/usr/lib" \
    -lxkbcommon \
    -o "$ROOT_DIR/usr/bin/xkb-test"

probe=$("$CROSS_LOADER" \
    --library-path "$CROSS_SYSROOT/lib:$ROOT_DIR/usr/lib:$GRAPHICS_SYSROOT/usr/lib" \
    "$ROOT_DIR/usr/bin/xkb-test") || cross_port_fail "the xkb keymap check failed"
printf '%s\n' "$probe"

"$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/xkb-test"

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR"

printf 'libxkbcommon %s staged at %s\n' "$version" "$ROOT_DIR"
