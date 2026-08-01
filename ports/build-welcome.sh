#!/usr/bin/env bash
set -euo pipefail

# Build the Tunix welcome screen -- one GTK3 C file, so it compiles directly
# with the cross toolchain instead of going through a build system.

PORT_NAME=welcome
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/welcome"
BUILD="$OUT/welcome-build"
ROOT_DIR="$OUT/welcome-root"

[[ -f "$SOURCE/tunix-welcome.c" ]] || cross_port_fail \
    "missing $SOURCE/tunix-welcome.c; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools pkg-config "$READELF"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/gtk+-3.0.pc" ]] || cross_port_fail \
    "gtk+-3.0 is not in the sysroot; build the gtk3 port first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_export_pkg_config
# xorgproto puts its .pc files in share/pkgconfig, and x11 requires them.
export PKG_CONFIG_LIBDIR="$GRAPHICS_SYSROOT/usr/lib/pkgconfig:$GRAPHICS_SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$GRAPHICS_SYSROOT"

GTK_CFLAGS=$(pkg-config --cflags gtk+-3.0)
GTK_LIBS=$(pkg-config --libs gtk+-3.0)

# shellcheck disable=SC2086
"$CROSS_CC" -Os -Wall -Wextra -o "$BUILD/tunix-welcome" \
    "$SOURCE/tunix-welcome.c" \
    $GTK_CFLAGS \
    -L"$GRAPHICS_SYSROOT/usr/lib" -Wl,-rpath-link,"$GRAPHICS_SYSROOT/usr/lib" \
    $GTK_LIBS

install -Dm755 "$BUILD/tunix-welcome" "$ROOT_DIR/usr/bin/tunix-welcome"
install -Dm644 "$SOURCE/tunix-welcome.desktop" \
    "$ROOT_DIR/usr/share/applications/tunix-welcome.desktop"
install -Dm644 "$SOURCE/assets/tunix.png" \
    "$ROOT_DIR/usr/share/tunix-welcome/assets/tunix.png"
install -Dm644 "$SOURCE/assets/tunix.png" \
    "$ROOT_DIR/usr/share/pixmaps/tunix.png"

cross_port_finalize_root "$ROOT_DIR"
# Everything it links comes from the gtk3 stack and the roots underneath it.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/gtk3-root" "$OUT/glib-root" \
    "$OUT/pango-root" "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/mesa-root" \
    "$OUT/libffi-root" "$OUT/pixman-root" "$OUT/libX11-root" "$OUT/xcb-root" \
    "$OUT/xext-root" "$OUT/libdrm-root" "$OUT/icu-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/llvm-root" "$OUT/libxml2-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'tunix-welcome staged at %s (%s)\n' "$ROOT_DIR" "$size"
