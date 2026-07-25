#!/usr/bin/env bash
set -euo pipefail

# Build libwnck for Tunix -- the Window Navigator Construction Kit (GNOME's
# window-list / pager / tasklist widget library, still the libwnck-3 API). It is
# a hard dependency of xfwm4 (and later xfce4-panel's window buttons), and the
# first GTK3 consumer that actually needs the X11 backend: it talks EWMH to the
# window manager over Xlib. That is why GTK3 was rebuilt with x11_backend=true
# and cairo with the xlib backend before this port.
#
# Output layout (the libxfce4ui.sh pattern):
#   $OUT/graphics-sysroot/usr/{include,lib,share}  headers + .pc for xfwm4
#   $OUT/libwnck-root/usr/{lib,share}              libwnck-3.so.0 + its data, image

PORT_NAME=libwnck
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libwnck"
BUILD="$OUT/libwnck-build"
ROOT_DIR="$OUT/libwnck-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config glib-mkenums "$READELF"

# The x11 backend (gdk-x11-3.0) is the whole point; fail early if GTK3 was still
# the wayland-only build.
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/gdk-x11-3.0.pc" ]] || cross_port_fail \
    "gdk-x11-3.0 is missing; rebuild GTK3 with x11_backend=true first"
for module in gtk+-3.0 glib-2.0 gobject-2.0 gio-2.0 x11 xres xi \
              libstartup-notification-1.0; do
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
    -Dintrospection=disabled \
    -Dgtk_doc=false \
    -Dinstall_tools=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libwnck-3.0.pc" ]] || \
    cross_port_fail "libwnck-3.0.pc was not installed into the graphics sysroot"

lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libwnck-3.so.0*' -print -quit)
[[ -n "$lib" ]] || cross_port_fail "libwnck-3.so.0 was not installed"
cross_port_check_library "$lib" libwnck-3.so.0

# The image keeps the library and its default window icons; headers, .pc,
# developer data and locale catalogues are dropped.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/gir-1.0" \
       "$ROOT_DIR/usr/share/locale"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root" "$OUT/xcb-util-root" \
    "$OUT/startup-notification-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libwnck 43.0 (libwnck-3.0 API) staged at %s (%s)\n' "$ROOT_DIR" "$size"
