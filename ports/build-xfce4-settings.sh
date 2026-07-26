#!/usr/bin/env bash
set -euo pipefail

# Build xfce4-settings for Tunix -- the settings daemon (xfsettingsd) and the
# settings dialogs. xfsettingsd is what makes the session apply its GTK theme,
# icon theme, fonts, cursor, keyboard and pointer settings from xfconf; without
# it every app falls back to the raw defaults. The dialogs (appearance, display,
# keyboard, mouse...) come along in the same build.
#
# Feature choices: x11 on, wayland off; colord, libnotify, libxklavier, upower,
# sound-settings and gtk-layer-shell all off -- none are ported and the daemon +
# core dialogs work without them.

PORT_NAME=xfce4-settings
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xfce4-settings"
BUILD="$OUT/xfce4-settings-build"
ROOT_DIR="$OUT/xfce4-settings-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-genmarshal glib-mkenums "$READELF"
for module in gtk+-3.0 gdk-x11-3.0 libxfce4ui-2 libxfce4util-1.0 libxfconf-0 \
              garcon-1 xi xrandr xcursor xkbregistry; do
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
    -Dcolord=disabled \
    -Dlibnotify=disabled \
    -Dlibxklavier=disabled \
    -Dupower=disabled \
    -Dsound-settings=false \
    -Dgtk-layer-shell=disabled
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/xfsettingsd" ]] || cross_port_fail "xfsettingsd was not installed"

# Keep bin + the settings dialogs' share data (glade UI, .desktop); drop
# dev/locale/doc.
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
    "$OUT/libxfce4ui-root" "$OUT/garcon-root" "$OUT/libxml2-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xfce4-settings (xfsettingsd + dialogs) staged at %s (%s)\n' "$ROOT_DIR" "$size"
