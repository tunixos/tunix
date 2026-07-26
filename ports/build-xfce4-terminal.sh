#!/usr/bin/env bash
set -euo pipefail

# Build xfce4-terminal for Tunix -- the Xfce terminal emulator, the one piece a
# daily-usable desktop cannot do without. A GTK3 app on VTE (the terminal
# widget) plus the usual libxfce4ui/util/xfconf. x11 on, wayland /
# gtk-layer-shell / libutempter off.

PORT_NAME=xfce4-terminal
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xfce4-terminal"
BUILD="$OUT/xfce4-terminal-build"
ROOT_DIR="$OUT/xfce4-terminal-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-genmarshal glib-mkenums "$READELF"
for module in gtk+-3.0 gdk-x11-3.0 vte-2.91 libxfce4ui-2 libxfce4util-1.0 \
              libxfconf-0 libpcre2-8; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release \
    -Dx11=enabled \
    -Dwayland=disabled \
    -Dgtk-layer-shell=disabled \
    -Dlibutempter=disabled \
    -Ddoc=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/xfce4-terminal" ]] || cross_port_fail "xfce4-terminal was not installed"

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/man"
find "$ROOT_DIR/usr/lib" -maxdepth 2 -name '*.a' -delete 2>/dev/null || true

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" "$OUT/libX11-root" "$OUT/xext-root" \
    "$OUT/xcb-root" "$OUT/xcb-util-root" "$OUT/startup-notification-root" \
    "$OUT/libsm-root" "$OUT/libxfce4util-root" "$OUT/xfconf-root" \
    "$OUT/libxfce4ui-root" "$OUT/vte-root" "$OUT/libxml2-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xfce4-terminal staged at %s (%s)\n' "$ROOT_DIR" "$size"
