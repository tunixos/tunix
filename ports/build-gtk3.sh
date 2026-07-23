#!/usr/bin/env bash
set -euo pipefail

# Build GTK 3 for Tunix: cairo-gobject, atk, libepoxy, then gtk itself.
#
# The Wayland backend only. GTK3 draws every widget with cairo into a wl_shm
# buffer, which is exactly the path weston's pixman renderer composites best;
# no GL is required anywhere in a stock GTK3 app. libepoxy is still a hard
# build dependency -- GdkGLContext exists whether or not anything uses it --
# and it dispatches to mesa's EGL/GLES at runtime only if an app asks for a
# GL area.
#
# The other three pieces, and why they are here rather than in their own
# ports:
#
#   cairo-gobject  cairo rebuilt with -Dglib=enabled. The cairo port builds
#                  before glib exists (weston needs it, weston does not need
#                  glib), so the GObject wrapper library could not be built
#                  there. Same source, same version, one extra library; only
#                  libcairo-gobject is kept from the rebuild so the cairo
#                  root remains the owner of libcairo itself.
#   atk            the accessibility interface library. GTK3 links it
#                  unconditionally; the at-spi *bus* bridge is X11-only and
#                  is not built.
#   libepoxy       the GL dispatch library, EGL-only here.
#
# Runtime details settled at build time:
#
#   gschemas.compiled   GTK aborts on first use of a schema (the file chooser
#                       does it immediately) if org.gtk.Settings.* are not
#                       compiled into the schema directory. The host's
#                       glib-compile-schemas writes the target file: the
#                       format is stable and architecture-independent.
#   hicolor index       icon lookup wants the hicolor fallback theme to
#                       exist; a minimal index.theme stops every app from
#                       warning about it.
#
# Output layout:
#   $OUT/gtk3-root/usr/lib          libgtk-3, libgdk-3, atk, epoxy, cairo-gobject
#   $OUT/gtk3-root/usr/bin          gtk3-demo, gtk3-widget-factory
#   $OUT/gtk3-root/usr/share        compiled gsettings schemas, themes, icons

PORT_NAME=gtk3
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

CAIRO_SOURCE="$ROOT/ports/src/cairo"
ATK_SOURCE="$ROOT/ports/src/atk"
EPOXY_SOURCE="$ROOT/ports/src/libepoxy"
GTK_SOURCE="$ROOT/ports/src/gtk"

BUILD="$OUT/gtk3-build"
ROOT_DIR="$OUT/gtk3-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_ATK_VERSION=2.38.0
EXPECTED_EPOXY_VERSION=1.5.10
EXPECTED_GTK_VERSION=3.24.52

for source in "$CAIRO_SOURCE/meson.build" "$ATK_SOURCE/meson.build" \
              "$EPOXY_SOURCE/meson.build" "$GTK_SOURCE/meson.build"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config python3 glib-compile-schemas \
    glib-compile-resources wayland-scanner "$READELF"

gtk_version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$GTK_SOURCE/meson.build" | head -n1)
[[ "$gtk_version" == "$EXPECTED_GTK_VERSION" ]] || \
    cross_port_fail "expected gtk $EXPECTED_GTK_VERSION, found ${gtk_version:-unknown}"

# Everything GTK3's wayland build reaches for.
for module in glib-2.0 gobject-2.0 gio-2.0 pango pangocairo cairo gdk-pixbuf-2.0 \
              harfbuzz fribidi wayland-client wayland-cursor wayland-egl xkbcommon \
              egl fontconfig freetype2; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done
[[ -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/wayland-protocols.pc" ]] || \
    cross_port_fail "wayland-protocols is missing; run ports/build-wayland-protocols.sh first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

install_both() {
    DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$1" --no-rebuild
    DESTDIR="$ROOT_DIR" meson install -C "$1" --no-rebuild
}

# libepoxy declares its version inline on the project() line rather than on a
# line of its own, so match anywhere in the line (same as build-pango.sh).
meson_version() {
    sed -n "s/.*[^_]version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
        "$1/meson.build" | head -n1
}

# --- cairo-gobject -------------------------------------------------------
# The full cairo build again, glib enabled this time. It installs the same
# libcairo the cairo port already ships, so after install everything except
# the new libcairo-gobject is pruned from this root; the sysroot copy is left
# alone (same version, and gtk needs cairo-gobject.pc there).
meson setup "$BUILD/cairo-gobject" "$CAIRO_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dfreetype=enabled -Dpng=enabled -Dzlib=enabled -Dfontconfig=enabled \
    -Dglib=enabled \
    -Dxlib=disabled -Dxcb=disabled -Dquartz=disabled -Dtee=disabled \
    -Dspectre=disabled -Dsymbol-lookup=disabled -Dtests=disabled \
    -Dgtk2-utils=disabled
meson compile -C "$BUILD/cairo-gobject" -j "$JOBS"
install_both "$BUILD/cairo-gobject"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/cairo-gobject.pc" ]] || \
    cross_port_fail "cairo-gobject.pc was not installed"
find "$ROOT_DIR/usr/lib" -maxdepth 1 \( -name 'libcairo.*' -o -name 'libcairo-script*' \) -delete
rm -rf "$ROOT_DIR/usr/bin"

# --- atk -----------------------------------------------------------------
atk_version=$(meson_version "$ATK_SOURCE")
[[ "$atk_version" == "$EXPECTED_ATK_VERSION" ]] || \
    cross_port_fail "expected atk $EXPECTED_ATK_VERSION, found ${atk_version:-unknown}"
meson setup "$BUILD/atk" "$ATK_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=false -Ddocs=false
meson compile -C "$BUILD/atk" -j "$JOBS"
install_both "$BUILD/atk"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/atk.pc" ]] || \
    cross_port_fail "atk.pc was not installed"

# --- libepoxy ------------------------------------------------------------
epoxy_version=$(meson_version "$EPOXY_SOURCE")
[[ "$epoxy_version" == "$EXPECTED_EPOXY_VERSION" ]] || \
    cross_port_fail "expected libepoxy $EXPECTED_EPOXY_VERSION, found ${epoxy_version:-unknown}"
meson setup "$BUILD/libepoxy" "$EPOXY_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dglx=no -Degl=yes -Dx11=false -Dtests=false
meson compile -C "$BUILD/libepoxy" -j "$JOBS"
install_both "$BUILD/libepoxy"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/epoxy.pc" ]] || \
    cross_port_fail "epoxy.pc was not installed"

# --- gtk3 ----------------------------------------------------------------
# print_backends=file: the option does not accept an empty list, and the file
# backend has no dependencies. colord/cups/cloudproviders are daemons and
# services Tunix does not run.
meson setup "$BUILD/gtk" "$GTK_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dwayland_backend=true \
    -Dx11_backend=false \
    -Dbroadway_backend=false \
    -Dwin32_backend=false \
    -Dquartz_backend=false \
    -Dprint_backends=file \
    -Dcolord=no \
    -Dcloudproviders=false \
    -Dtracker3=false \
    -Dprofiler=false \
    -Dbuiltin_immodules=backend \
    -Dintrospection=false \
    -Dgtk_doc=false \
    -Dman=false \
    -Ddemos=true \
    -Dexamples=false \
    -Dtests=false \
    -Dinstalled_tests=false
meson compile -C "$BUILD/gtk" -j "$JOBS"
install_both "$BUILD/gtk"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/gtk+-3.0.pc" ]] || \
    cross_port_fail "gtk+-3.0.pc was not installed into the graphics sysroot"

# --- gsettings schemas ---------------------------------------------------
# Compiled on the host; the binary format is architecture-independent.
[[ -d "$ROOT_DIR/usr/share/glib-2.0/schemas" ]] || \
    cross_port_fail "gtk installed no gsettings schemas"
glib-compile-schemas "$ROOT_DIR/usr/share/glib-2.0/schemas"
[[ -f "$ROOT_DIR/usr/share/glib-2.0/schemas/gschemas.compiled" ]] || \
    cross_port_fail "gschemas.compiled was not produced"

# --- hicolor fallback theme ----------------------------------------------
# GTK *aborts* (gtkiconhelper.c ensure_surface_for_gicon assertion) if even
# the image-missing fallback icon cannot be found in any theme. The gtk
# source tree ships the fallback set itself -- image-missing, the stock
# action arrows, dialog icons -- as flat PNGs under gtk/icons; installed as
# the hicolor theme they are found by every lookup chain (the default theme
# name "Adwaita" simply falls through to hicolor). ~600 KB.
HICOLOR="$ROOT_DIR/usr/share/icons/hicolor"
mkdir -p "$HICOLOR"
cp -R "$GTK_SOURCE/gtk/icons/." "$HICOLOR/"
[[ -f "$HICOLOR/16x16/status/image-missing.png" ]] || \
    cross_port_fail "gtk's fallback icons were not staged"

# index.theme is generated from what was actually copied, so a change in the
# gtk source layout shows up as a change here rather than as dead entries.
directories=""
for size_dir in "$HICOLOR"/*/; do
    size=$(basename "$size_dir")
    for context_dir in "$size_dir"*/; do
        [[ -d "$context_dir" ]] || continue
        context=$(basename "$context_dir")
        directories+="${directories:+,}$size/$context"
    done
done
{
    printf '[Icon Theme]\nName=Hicolor\nComment=Fallback icon theme\nDirectories=%s\n' \
        "$directories"
    IFS=',' read -ra entries <<< "$directories"
    for entry in "${entries[@]}"; do
        size=${entry%%/*}
        context=${entry##*/}
        # Capitalise the context the way the spec spells them.
        case "$context" in
            actions) context_name=Actions ;;
            categories) context_name=Categories ;;
            status) context_name=Status ;;
            *) context_name=$context ;;
        esac
        printf '\n[%s]\n' "$entry"
        if [[ "$size" == scalable ]]; then
            printf 'Size=48\nContext=%s\nType=Scalable\nMinSize=1\nMaxSize=512\n' \
                "$context_name"
        else
            printf 'Size=%s\nContext=%s\nType=Threshold\n' "${size%%x*}" "$context_name"
        fi
    done
} > "$HICOLOR/index.theme"

for spec in "libcairo-gobject.so.2:libcairo-gobject.so.2" "libatk-1.0.so.0:libatk-1.0.so.0" \
            "libepoxy.so.0:libepoxy.so.0" "libgdk-3.so.0:libgdk-3.so.0" \
            "libgtk-3.so.0:libgtk-3.so.0"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done
[[ -x "$ROOT_DIR/usr/bin/gtk3-widget-factory" ]] || \
    cross_port_fail "gtk3-widget-factory was not produced"
[[ -x "$ROOT_DIR/usr/bin/gtk3-demo" ]] || \
    cross_port_fail "gtk3-demo was not produced"

# usr/share keeps the schemas, themes and icons; the developer keys are not
# needed. gtk-query-immodules and friends only matter for module caches we do
# not use; the demos stay.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/libexec" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/gettext" \
       "$ROOT_DIR/usr/share/aclocal" "$ROOT_DIR/usr/share/gir-1.0"
# 28 MB of message catalogues for a system built with nls disabled everywhere
# else, 4 MB of emoji picker data for a font with no emoji glyphs, and
# valgrind suppressions for a tool that is not ported.
rm -rf "$ROOT_DIR/usr/share/locale" "$ROOT_DIR/usr/share/gtk-3.0/emoji" \
       "$ROOT_DIR/usr/share/gtk-3.0/valgrind"
for tool in gtk-builder-tool gtk-encode-symbolic-svg gtk-launch \
            gtk-query-immodules-3.0 gtk-query-settings gtk-update-icon-cache \
            broadwayd gtk3-demo-application; do
    rm -f "$ROOT_DIR/usr/bin/$tool"
done
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/gtk3-widget-factory" 2>/dev/null || true
"$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/gtk3-demo" 2>/dev/null || true

# mesa-root ships libstdc++/libgcc_s (harfbuzz is C++), wayland-root the
# wayland client libraries, and the rest of the stack is spread across the
# roots below; together they must satisfy every NEEDED entry.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" \
    "$OUT/pixman-root" "$OUT/libffi-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'gtk %s (atk %s, libepoxy %s, cairo-gobject) staged at %s (%s)\n' \
    "$gtk_version" "$atk_version" "$epoxy_version" "$ROOT_DIR" "$size"
