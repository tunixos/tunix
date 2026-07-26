#!/usr/bin/env bash
set -euo pipefail

# Build VTE for Tunix -- the GNOME virtual-terminal widget (libvte-2.91), the
# engine behind xfce4-terminal. Pinned to 0.72.2: newer VTE pulls in {fmt},
# simdutf and fast_float (C++ libraries not ported), while 0.72 needs only the
# GTK3 stack, pcre2 (from glib), fribidi, icu and zlib -- all already here. gtk4,
# gnutls, systemd, introspection and vala are off.
#
# VTE is C++, so libstdc++/libgcc_s (staged with mesa) come along in the closure.
#
# Output: libvte-2.91.so.0 + vte-2.91.pc to the sysroot; the .so to the image.

PORT_NAME=vte
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/vte"
PATCH_DIR="$ROOT/ports/src/patches/vte"
BUILD="$OUT/vte-build"
ROOT_DIR="$OUT/vte-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config gperf "$READELF"
for module in gtk+-3.0 glib-2.0 gio-2.0 pango libpcre2-8 fribidi icu-uc zlib; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

# Patch a copy, never ports/src: one patch defines W_EXITCODE, a glibc macro
# widget.cc uses that musl does not ship.
SRC="$BUILD/src"
mkdir -p "$SRC"
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$SRC" -xf -
patches=("$PATCH_DIR"/*.patch)
[[ -e "${patches[0]}" ]] || cross_port_fail "no patches found in $PATCH_DIR"
for patch in "${patches[@]}"; do
    patch -p1 -d "$SRC" --fuzz=0 --forward < "$patch" ||
        cross_port_fail "failed to apply $(basename "$patch")"
done

meson setup "$BUILD/obj" "$SRC" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dgtk3=true \
    -Dgtk4=false \
    -Dgnutls=false \
    -D_systemd=false \
    -Dgir=false \
    -Dvapi=false \
    -Dglade=false \
    -Da11y=false \
    -Ddocs=false \
    -Dfribidi=true \
    -Dicu=true
meson compile -C "$BUILD/obj" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/obj" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/obj" --no-rebuild

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/vte-2.91.pc" ]] || \
    cross_port_fail "vte-2.91.pc was not installed into the sysroot"

lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libvte-2.91.so.0*' -print -quit)
[[ -n "$lib" ]] || cross_port_fail "libvte-2.91.so.0 was not installed"
cross_port_check_library "$lib" libvte-2.91.so.0

# Keep the library and vte's terminfo/gsettings data; drop dev/locale/doc and the
# demo binary.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/libexec" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/gir-1.0" "$ROOT_DIR/usr/share/vala"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# mesa-root ships libstdc++/libgcc_s (VTE is C++); icu-root the ICU libraries.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" "$OUT/libX11-root" "$OUT/xext-root" \
    "$OUT/xcb-root" "$OUT/libxml2-root" "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'vte 0.72.2 (libvte-2.91) staged at %s (%s)\n' "$ROOT_DIR" "$size"
