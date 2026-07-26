#!/usr/bin/env bash
set -euo pipefail

# Build xfce4-panel for Tunix -- the Xfce panel (taskbar): the window buttons,
# applications menu, clock, systray host and the plugin host itself. The most
# visible piece of the Xfce session. Links garcon (menu), libwnck +
# libxfce4windowing (windows/workspaces), libxfce4ui and xfconf.
#
# Feature choices: x11 on, wayland off (the session runs on Xorg); dbusmenu
# (StatusNotifier/appindicator host), gtk-layer-shell, introspection and vala all
# off -- none are ported and the panel works without them.

PORT_NAME=xfce4-panel
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xfce4-panel"
BUILD="$OUT/xfce4-panel-build"
ROOT_DIR="$OUT/xfce4-panel-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-genmarshal glib-mkenums "$READELF"
for module in gtk+-3.0 gdk-x11-3.0 libxfce4ui-2 libxfce4util-1.0 libxfconf-0 \
              garcon-1 garcon-gtk3-1 libwnck-3.0 libxfce4windowing-0 \
              libxfce4windowing-x11-0 libxfce4windowingui-0; do
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
    -Ddbusmenu=disabled \
    -Dgtk-layer-shell=disabled \
    -Dintrospection=false \
    -Dvala=disabled \
    -Dgtk-doc=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/xfce4-panel" ]] || cross_port_fail "xfce4-panel was not installed"

# Leaf app: keep bin + the plugins (usr/lib/xfce4/panel), the default layout and
# the plugin .desktop files under share; drop dev/locale/doc.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/gir-1.0" \
       "$ROOT_DIR/usr/share/vala"
find "$ROOT_DIR/usr/lib" -maxdepth 2 -name '*.a' -delete 2>/dev/null || true

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" "$OUT/libX11-root" "$OUT/xext-root" \
    "$OUT/xcb-root" "$OUT/xcb-util-root" "$OUT/startup-notification-root" \
    "$OUT/libwnck-root" "$OUT/libsm-root" "$OUT/libxfce4util-root" "$OUT/xfconf-root" \
    "$OUT/libxfce4ui-root" "$OUT/garcon-root" "$OUT/libxfce4windowing-root" \
    "$OUT/libdisplay-info-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xfce4-panel staged at %s (%s)\n' "$ROOT_DIR" "$size"
