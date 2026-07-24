#!/usr/bin/env bash
set -euo pipefail

# Build libxfce4ui for Tunix -- the Xfce GTK widget library, and the last
# dependency below Thunar itself. It ships two libraries Thunar links:
#   libxfce4ui-2          the widgets (dialogs, the filename input, GtkBuilder
#                         helpers)
#   libxfce4kbd-private-3 the shortcut/keyboard helper (Thunar's accelerators)
#
# Backend selection is the whole story here. libxfce4ui builds an X11 and a
# Wayland path and errors out if neither is enabled; our GTK3 is wayland-only,
# so x11 is turned off and wayland (gdk-wayland-3.0, already in the sysroot) is
# turned on. Everything that is "X11 only" upstream -- session management
# (libSM/libICE) and startup-notification -- goes off with it, and the optional
# system-info extras (libgtop, and the epoxy/gudev features that upstream gates
# behind libgtop) are off too, since none are ported.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib,share}  headers + .pc for Thunar
#   $OUT/libxfce4ui-root/usr/lib                   the two shared libraries +
#                                                  the widget icons, for the image

PORT_NAME=libxfce4ui
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libxfce4ui"
BUILD="$OUT/libxfce4ui-build"
ROOT_DIR="$OUT/libxfce4ui-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_VERSION=4.21.9

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init --recursive"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-mkenums glib-genmarshal "$READELF"

version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected libxfce4ui $EXPECTED_VERSION, found ${version:-unknown}"

for module in gtk+-3.0 gdk-pixbuf-2.0 gdk-wayland-3.0 glib-2.0 gio-2.0 gthread-2.0 \
              libxfce4util-1.0 libxfconf-0; do
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
    -Dvala=disabled \
    -Dgtk-doc=false \
    -Dkeyboard-library=true \
    -Dx11=disabled \
    -Dwayland=enabled \
    -Dsession-management=disabled \
    -Dstartup-notification=disabled \
    -Dlibgtop=disabled \
    -Depoxy=disabled \
    -Dgudev=disabled
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

for pc in libxfce4ui-2 libxfce4kbd-private-3; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed into the graphics sysroot"
done

for spec in "libxfce4ui-2.so.0:libxfce4ui-2.so.0" \
            "libxfce4kbd-private-3.so.0:libxfce4kbd-private-3.so.0"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done

# The image keeps the two libraries and their widget icons (a missing icon can
# abort a GTK lookup). The about/open helper binaries, headers, .pc, developer
# data and locale catalogues are dropped.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/libexec" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/aclocal" \
       "$ROOT_DIR/usr/share/locale" "$ROOT_DIR/usr/share/gir-1.0" \
       "$ROOT_DIR/usr/share/vala" "$ROOT_DIR/usr/share/glade" \
       "$ROOT_DIR/usr/share/applications" "$ROOT_DIR/usr/share/metainfo"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# icu-root is in the list because pango-root ships libharfbuzz-icu (harfbuzz was
# rebuilt with icu for webkit), whose NEEDED libicuuc.so.77 the closure walk
# would otherwise flag -- libxfce4ui itself never touches it.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/libxfce4util-root" "$OUT/xfconf-root" "$OUT/icu-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libxfce4ui %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
