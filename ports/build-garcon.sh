#!/usr/bin/env bash
set -euo pipefail

# Build garcon for Tunix -- the freedesktop.org menu library (libgarcon-1) plus
# its GTK3 menu widget (libgarcon-gtk3-1). xfce4-panel's applications menu,
# xfdesktop's right-click menu and xfce4-settings all build against it, so it is
# the first library of the Xfce *session* layer, above the widget/config stack.
#
# A GTK3 meson library (the libwnck.sh pattern): headers + .pc to the graphics
# sysroot, the two shared libraries + the menu data to the image root.

PORT_NAME=garcon
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/garcon"
BUILD="$OUT/garcon-build"
ROOT_DIR="$OUT/garcon-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility glib-mkenums "$READELF"
for module in gtk+-3.0 glib-2.0 gio-2.0 libxfce4util-1.0 libxfce4ui-2; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=false \
    -Dgtk-doc=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

for pc in garcon-1 garcon-gtk3-1; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed into the graphics sysroot"
done

for spec in "libgarcon-1.so.0:libgarcon-1.so.0" \
            "libgarcon-gtk3-1.so.0:libgarcon-gtk3-1.so.0"; do
    name=${spec%%:*}; soname=${spec##*:}
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$lib" "$soname"
done

# Keep the libraries and the menu data (garcon reads the .menu/.directory files
# at runtime); drop dev files, docs and locale.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/gir-1.0"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" "$OUT/libX11-root" "$OUT/xext-root" \
    "$OUT/xcb-root" "$OUT/libxfce4util-root" "$OUT/xfconf-root" "$OUT/libxfce4ui-root" \
    "$OUT/libsm-root" "$OUT/startup-notification-root" "$OUT/xcb-util-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'garcon (libgarcon-1 + libgarcon-gtk3-1) staged at %s (%s)\n' "$ROOT_DIR" "$size"
