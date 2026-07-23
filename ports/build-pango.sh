#!/usr/bin/env bash
set -euo pipefail

# Build the text-shaping stack for Tunix: fribidi, harfbuzz, then pango.
#
# Pango is what turns "draw this string in this font" into positioned glyphs
# for GTK; cairo (already ported) only rasterises what pango lays out. Like
# the cairo chain, these three live in one script because each is only a
# dependency of the next:
#
#   fribidi   the Unicode bidirectional algorithm; pango requires it even for
#             a system that will mostly draw left-to-right ASCII
#   harfbuzz  the shaper: maps codepoints to glyph indices and positions via
#             the font's own OpenType tables
#   pango     the layout engine GTK actually calls
#
# harfbuzz choices: freetype on (that is how it reaches the font files that
# fontconfig resolves), glib on (pango and gtk both want hb's glib
# integration), everything else -- cairo glue, ICU, gobject introspection --
# off because pango brings its own cairo path and nothing here consumes the
# rest.
#
# pango choices: fontconfig+freetype+cairo on (the whole point), xft off (no
# X), libthai off (no Thai locale data on the image).
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for gtk
#   $OUT/pango-root/usr/lib                   the shared libraries

PORT_NAME=pango
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

FRIBIDI_SOURCE="$ROOT/ports/src/fribidi"
HARFBUZZ_SOURCE="$ROOT/ports/src/harfbuzz"
PANGO_SOURCE="$ROOT/ports/src/pango"
PATCH_DIR="$ROOT/ports/src/patches/pango"

BUILD="$OUT/pango-build"
ROOT_DIR="$OUT/pango-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_FRIBIDI_VERSION=1.0.16
EXPECTED_HARFBUZZ_VERSION=11.5.1
EXPECTED_PANGO_VERSION=1.56.4

for source in "$FRIBIDI_SOURCE/meson.build" "$HARFBUZZ_SOURCE/meson.build" \
              "$PANGO_SOURCE/meson.build"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config python3 "$READELF"

# Pango sits on glib and the cairo/fontconfig/freetype chain.
for module in glib-2.0 gobject-2.0 gio-2.0 cairo fontconfig freetype2; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

install_both() {
    DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$1" --no-rebuild
    DESTDIR="$ROOT_DIR" meson install -C "$1" --no-rebuild
}

check_version() {
    local name="$1" found="$2" expected="$3"
    [[ "$found" == "$expected" ]] || \
        cross_port_fail "expected $name $expected, found ${found:-unknown}"
}

# fribidi declares its version inline on the project() line rather than on a
# line of its own, so match anywhere in the line; meson_version's '>= x.y'
# value cannot match because the quote is followed by '>'.
meson_version() {
    sed -n "s/.*[^_]version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
        "$1/meson.build" | head -n1
}

# --- fribidi -------------------------------------------------------------
check_version fribidi "$(meson_version "$FRIBIDI_SOURCE")" "$EXPECTED_FRIBIDI_VERSION"
meson setup "$BUILD/fribidi" "$FRIBIDI_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Ddocs=false -Dtests=false -Dbin=false
meson compile -C "$BUILD/fribidi" -j "$JOBS"
install_both "$BUILD/fribidi"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/fribidi.pc" ]] || \
    cross_port_fail "fribidi.pc was not installed"

# --- harfbuzz ------------------------------------------------------------
check_version harfbuzz "$(meson_version "$HARFBUZZ_SOURCE")" "$EXPECTED_HARFBUZZ_VERSION"
meson setup "$BUILD/harfbuzz" "$HARFBUZZ_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dfreetype=enabled \
    -Dglib=enabled \
    -Dgobject=disabled \
    -Dcairo=disabled \
    -Dicu=disabled \
    -Dgraphite2=disabled \
    -Dintrospection=disabled \
    -Dtests=disabled \
    -Ddocs=disabled \
    -Dbenchmark=disabled \
    -Dutilities=disabled
meson compile -C "$BUILD/harfbuzz" -j "$JOBS"
install_both "$BUILD/harfbuzz"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/harfbuzz.pc" ]] || \
    cross_port_fail "harfbuzz.pc was not installed"

# --- pango ---------------------------------------------------------------
check_version pango "$(meson_version "$PANGO_SOURCE")" "$EXPECTED_PANGO_VERSION"

# Patch a copy, never ports/src -- same discipline as weston. patch(1) with
# --fuzz=0 so drift after a pango bump fails loudly instead of guessing.
rm -rf "$BUILD/pango-src"
mkdir -p "$BUILD/pango-src"
tar -C "$PANGO_SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/pango-src" -xf -
patches=("$PATCH_DIR"/*.patch)
[[ -e "${patches[0]}" ]] || cross_port_fail "no patches found in $PATCH_DIR"
for patch_file in "${patches[@]}"; do
    patch -p1 -d "$BUILD/pango-src" --fuzz=0 --forward < "$patch_file" ||
        cross_port_fail "failed to apply $(basename "$patch_file"); it has probably drifted from pango $EXPECTED_PANGO_VERSION"
done
grep -q 'fcfreetype.h' "$BUILD/pango-src/pango/pangofc-fontmap.c" || \
    cross_port_fail "the fcfreetype patch reported success but changed nothing"

meson setup "$BUILD/pango" "$BUILD/pango-src" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=disabled \
    -Ddocumentation=false \
    -Dbuild-testsuite=false \
    -Dbuild-examples=false \
    -Dfontconfig=enabled \
    -Dfreetype=enabled \
    -Dcairo=enabled \
    -Dxft=disabled \
    -Dlibthai=disabled
meson compile -C "$BUILD/pango" -j "$JOBS"
install_both "$BUILD/pango"

for pc in pango pangocairo pangoft2; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed into the graphics sysroot"
done

for spec in "libfribidi.so.0:libfribidi.so.0" "libharfbuzz.so.0:libharfbuzz.so.0" \
            "libpango-1.0.so.0:libpango-1.0.so.0" \
            "libpangocairo-1.0.so.0:libpangocairo-1.0.so.0" \
            "libpangoft2-1.0.so.0:libpangoft2-1.0.so.0"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/share"
# hb-subset is for font subsetting tools (pdf embedders and the like); nothing
# on the image links it.
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name 'libharfbuzz-subset*' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# mesa-root is in the closure list because it is what ships libstdc++ and
# libgcc_s, and harfbuzz is C++; libffi and pixman close over glib and cairo.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/cairo-root" \
    "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/libffi-root" "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'pango %s (fribidi %s, harfbuzz %s) staged at %s (%s)\n' \
    "$EXPECTED_PANGO_VERSION" "$EXPECTED_FRIBIDI_VERSION" "$EXPECTED_HARFBUZZ_VERSION" \
    "$ROOT_DIR" "$size"
