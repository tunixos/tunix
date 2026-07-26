#!/usr/bin/env bash
set -euo pipefail

# Build libxfce4windowing for Tunix -- Xfce's windowing-system abstraction
# (libxfce4windowing-0 core + libxfce4windowingui-0 widgets). Xfce 4.18+ split
# this out of xfwm4/libwnck so xfce4-panel, xfdesktop and xfce4-session can talk
# to windows/workspaces without caring whether the display is X11 or Wayland.
# We build the x11 backend only (the Tunix Xfce session runs on Xorg); it reads
# monitor info through libdisplay-info (already in the sysroot).
#
# A GTK3 meson library (the garcon.sh pattern): headers + .pc to the sysroot, the
# shared libraries to the image root.

PORT_NAME=libxfce4windowing
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libxfce4windowing"
BUILD="$OUT/libxfce4windowing-build"
ROOT_DIR="$OUT/libxfce4windowing-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility glib-mkenums "$READELF"
for module in gtk+-3.0 gdk-x11-3.0 glib-2.0 gio-2.0 gdk-pixbuf-2.0 x11 \
              libdisplay-info; do
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
    -Dx11=enabled \
    -Dwayland=disabled \
    -Dintrospection=false \
    -Dvala=disabled \
    -Dgtk-doc=false \
    -Dtests=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

for pc in libxfce4windowing-0 libxfce4windowingui-0; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed into the graphics sysroot"
done

for spec in "libxfce4windowing-0.so.0:libxfce4windowing-0.so.0" \
            "libxfce4windowingui-0.so.0:libxfce4windowingui-0.so.0"; do
    name=${spec%%:*}; soname=${spec##*:}
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$lib" "$soname"
done

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
    "$OUT/xcb-root" "$OUT/libdisplay-info-root" "$OUT/libwnck-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libxfce4windowing (core + ui, x11) staged at %s (%s)\n' "$ROOT_DIR" "$size"
