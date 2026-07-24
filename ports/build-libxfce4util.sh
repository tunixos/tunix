#!/usr/bin/env bash
set -euo pipefail

# Build libxfce4util for Tunix -- the base Xfce utility library and the first
# rung of the Thunar dependency ladder.
#
# It is a pure GLib consumer: libxfce4util.so.7 links glib/gobject/gio and
# nothing else from the graphics stack, so it drops straight onto the sysroot
# the GTK3 port already populated. No GTK, no X11, no D-Bus here -- those come
# further up the chain (exo, libxfce4ui, xfconf).
#
# Host build tools beyond the usual meson trio:
#   xdt-gen-visibility  from xfce4-dev-tools; generates the symbol-visibility
#                       header every Xfce library includes. required: true in
#                       meson.build, so it must be on PATH (pacman -S
#                       xfce4-dev-tools on the Arch build host).
#
# introspection/vala/gtk-doc are all disabled: no girepository host stack, no
# vapigen, and the HTML docs are build-time noise.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib,share}  headers + .pc for the ports
#                                                  above (xfconf, exo, ...)
#   $OUT/libxfce4util-root/usr/lib                 the shared library, for the image

PORT_NAME=libxfce4util
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libxfce4util"
BUILD="$OUT/libxfce4util-build"
ROOT_DIR="$OUT/libxfce4util-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_VERSION=4.20.1

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init --recursive"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility glib-mkenums "$READELF"

version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected libxfce4util $EXPECTED_VERSION, found ${version:-unknown}"

# Everything it links against is already staged by the glib port.
for module in glib-2.0 gobject-2.0 gio-2.0; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build the glib port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=false \
    -Dvala=disabled \
    -Dgtk-doc=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libxfce4util-1.0.pc" ]] || \
    cross_port_fail "libxfce4util-1.0.pc was not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/include/xfce4/libxfce4util/libxfce4util.h" ]] || \
    cross_port_fail "libxfce4util headers were not installed into the graphics sysroot"

library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libxfce4util.so.7*' -print -quit)
[[ -n "$library" ]] || cross_port_fail "libxfce4util.so.7 was not installed"
cross_port_check_library "$library" "libxfce4util.so.7"

# The image needs the library only. Headers, .pc, the kiosk-query helper and the
# generated GSettings/locale data are build-time or developer artefacts; the
# sysroot copy keeps whatever the ports above need.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/share/man" \
       "$ROOT_DIR/usr/share/doc" "$ROOT_DIR/usr/share/gtk-doc" \
       "$ROOT_DIR/usr/share/aclocal" "$ROOT_DIR/usr/share/locale"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/cairo-root" \
    "$OUT/libffi-root" "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libxfce4util %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
