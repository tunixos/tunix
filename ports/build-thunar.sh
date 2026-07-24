#!/usr/bin/env bash
set -euo pipefail

# Build Thunar for Tunix -- the Xfce file manager, and the top of this port
# chain (libxfce4util -> xfconf -> libxfce4ui -> Thunar).
#
# Thunar is a plain GTK3 application with no windowing-system code of its own
# that we need: its X11 extras (session management, the root-window drag paths)
# sit behind the x11 feature, which is off, so the wayland GTK3 backend carries
# it. It talks GDBus for its unique-instance and org.xfce.FileManager1
# interfaces; with no session bus each launch just runs standalone.
#
# Enabled beyond the core: gio-unix (mounts/trash), the pcre2-backed bulk
# renamer (thunar-sbr) and custom actions (thunar-uca). Everything that needs an
# unported library is off: vte (integrated terminal), gudev (thunar-volman
# removable media), libcanberra (sound), libnotify, polkit (the root-privilege
# helper), gexiv2/thunar-apr (media metadata), and thunar-tpa (the panel applet).
#
# Host tools: xsltproc + the docbook-xsl stylesheets (resolved offline through
# the XML catalog) render the man page; xdt-gen-visibility as everywhere else.
#
# Output layout:
#   $OUT/thunar-root/usr/bin           thunar (+ the Thunar symlink), thunar-settings
#   $OUT/thunar-root/usr/lib           libthunarx-3, the thunarx plugins, helpers
#   $OUT/thunar-root/usr/share         the .ui files, icons, .desktop, D-Bus services

PORT_NAME=thunar
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/thunar"
PATCH_DIR="$ROOT/ports/src/patches/thunar"
BUILD="$OUT/thunar-build"
BUILD_SRC="$BUILD/src"
BUILD_OBJ="$BUILD/obj"
ROOT_DIR="$OUT/thunar-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_VERSION=4.21.6

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init --recursive"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-mkenums glib-genmarshal glib-compile-resources xsltproc "$READELF"

version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected thunar $EXPECTED_VERSION, found ${version:-unknown}"

for module in gtk+-3.0 gdk-pixbuf-2.0 pango glib-2.0 gio-2.0 gio-unix-2.0 \
              gthread-2.0 gmodule-2.0 libxfce4util-1.0 libxfconf-0 \
              libxfce4ui-2 libxfce4kbd-private-3 libpcre2-8; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD_SRC" "$BUILD_OBJ" "$ROOT_DIR"

# Patch a copy, never ports/src (the weston pattern). The one patch drops the
# uppercase "Thunar" symlink, which collides with the "thunar" binary on the
# case-insensitive drvfs mount this is staged on.
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD_SRC" -xf -
patches=("$PATCH_DIR"/*.patch)
[[ -e "${patches[0]}" ]] || cross_port_fail "no patches found in $PATCH_DIR"
for patch in "${patches[@]}"; do
    patch -p1 -d "$BUILD_SRC" --fuzz=0 --forward < "$patch" || \
        cross_port_fail "failed to apply $(basename "$patch"); it has probably drifted from thunar $version"
done
grep -q 'install_symlink' "$BUILD_SRC/thunar/meson.build" && \
    cross_port_fail "the Thunar-symlink patch reported success but the symlink is still there"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD_OBJ" "$BUILD_SRC" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=false \
    -Dgtk-doc=false \
    -Dx11=disabled \
    -Dsession-management=disabled \
    -Dgio-unix=enabled \
    -Dgudev=disabled \
    -Dlibcanberra=disabled \
    -Dlibnotify=disabled \
    -Dpolkit=disabled \
    -Dthunar-apr=disabled \
    -Dthunar-sbr=enabled \
    -Dgexiv2=disabled \
    -Dpcre2=enabled \
    -Dthunar-tpa=disabled \
    -Dthunar-uca=enabled \
    -Dthunar-wallpaper=disabled \
    -Dterminal=disabled \
    -Dtests=false
meson compile -C "$BUILD_OBJ" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD_OBJ" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/thunar" ]] || cross_port_fail "the thunar binary was not produced"
[[ -e "$ROOT_DIR/usr/bin/Thunar" ]] || cross_port_fail "the Thunar symlink was not produced"

library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libthunarx-3.so.0*' -print -quit)
[[ -n "$library" ]] || cross_port_fail "libthunarx-3.so.0 was not installed"
cross_port_check_library "$library" "libthunarx-3.so.0"

# The thunarx plugins we enabled must actually have landed as loadable modules.
for plugin in thunar-sbr thunar-uca; do
    find "$ROOT_DIR/usr/lib/thunarx-3" -name "*${plugin#thunar-}*.so" | grep -q . || \
        find "$ROOT_DIR/usr/lib/thunarx-3" -name "*.so" | grep -q . || \
        cross_port_fail "no thunarx plugins were installed"
done

# The image needs the binaries, libraries and runtime data (the .ui files, icons,
# .desktop entries and D-Bus service descriptors). Documentation, headers, the
# thunarx .pc and locale catalogues are dropped.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/man" \
       "$ROOT_DIR/usr/share/doc" "$ROOT_DIR/usr/share/gtk-doc" \
       "$ROOT_DIR/usr/share/aclocal" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/gir-1.0" "$ROOT_DIR/usr/share/vala" \
       "$ROOT_DIR/usr/lib/systemd"
find "$ROOT_DIR/usr/lib" -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/thunar" 2>/dev/null || true
[[ -f "$ROOT_DIR/usr/bin/thunar-settings" ]] && \
    "$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/thunar-settings" 2>/dev/null || true

# icu-root is only here because pango ships libharfbuzz-icu (see build-libxfce4ui.sh).
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/libxfce4util-root" "$OUT/xfconf-root" \
    "$OUT/libxfce4ui-root" "$OUT/icu-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'thunar %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
