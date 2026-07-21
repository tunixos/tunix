#!/usr/bin/env bash
set -euo pipefail

# Build the cairo stack for Tunix: zlib, libpng, freetype, expat, fontconfig
# and cairo, plus the font they all exist to draw with.
#
# Weston needs cairo. That is not obvious from its options -- the demo clients
# and the GL renderer are the visible consumers and both are off here -- but
# libweston's headless backend itself includes gl-borders.h, which includes
# cairo-util.h, which includes cairo.h. There is no build without it.
#
# They are built together, in this order, because each is only a dependency of
# the next and nothing else wants them individually:
#
#   zlib, libpng  feed freetype and cairo's PNG surface
#   freetype      rasterises glyphs
#   expat         parses fontconfig's XML configuration, and nothing else
#   fontconfig    turns a family name into a face
#   cairo         draws
#
# fontconfig is the link that is easy to skip and expensive to skip. Without it
# cairo's FreeType backend reports every toy font face unsupported and falls
# back to `twin`, the vector font compiled into cairo itself -- so every client
# renders in the same hard-wired typeface whatever family it asks for, and
# weston-terminal's --font option does nothing at all. It cannot be built
# before freetype and cairo cannot be built before it, which is why the whole
# chain lives in one script.
#
# The font is JetBrains Mono under the SIL Open Font License: four faces
# (regular, bold, italic, bold italic) of the family's eighteen -- the rest are
# weights nothing here asks for.
#
# Deliberately off: the X11 and quartz surfaces, glib, and the test suites.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for weston
#   $OUT/cairo-root/usr/lib                   the shared libraries
#   $OUT/cairo-root/usr/share/fonts           the TTFs
#   $OUT/cairo-root/etc/fonts                 fontconfig's configuration

PORT_NAME=cairo
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

ZLIB_SOURCE="$ROOT/ports/src/zlib"
LIBPNG_SOURCE="$ROOT/ports/src/libpng"
FREETYPE_SOURCE="$ROOT/ports/src/freetype"
EXPAT_SOURCE="$ROOT/ports/src/libexpat/expat"
FONTCONFIG_SOURCE="$ROOT/ports/src/fontconfig"
FONT_SOURCE="$ROOT/ports/src/jetbrains-mono"
CAIRO_SOURCE="$ROOT/ports/src/cairo"

BUILD="$OUT/cairo-build"
ROOT_DIR="$OUT/cairo-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"
CMAKE_FILE="$OUT/tunix-cmake-cross.cmake"

EXPECTED_CAIRO_VERSION=1.18.4

for source in "$ZLIB_SOURCE/zlib.h" "$LIBPNG_SOURCE/png.h" \
              "$FREETYPE_SOURCE/meson.build" "$EXPAT_SOURCE/CMakeLists.txt" \
              "$FONTCONFIG_SOURCE/meson.build" "$CAIRO_SOURCE/meson.build"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done
[[ -d "$FONT_SOURCE/fonts/ttf" ]] || cross_port_fail \
    "missing JetBrains Mono at $FONT_SOURCE; run git submodule update --init --recursive"

cross_port_require_toolchain
cross_port_require_tools meson ninja cmake make pkg-config gperf python3 "$READELF"

EXPECTED_EXPAT_VERSION=2.8.2
EXPECTED_FONTCONFIG_VERSION=2.18.2

# cairo computes its version at configure time rather than writing a literal
# into meson.build, so ask the same script meson does.
cairo_version=$(cd "$CAIRO_SOURCE" && python3 version.py)
[[ "$cairo_version" == "$EXPECTED_CAIRO_VERSION" ]] || \
    cross_port_fail "expected cairo $EXPECTED_CAIRO_VERSION, found ${cairo_version:-unknown}"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/pixman-1.pc" ]] || \
    cross_port_fail "pixman is not in the graphics sysroot; run ports/build-pixman.sh first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_write_cmake_toolchain "$CMAKE_FILE"
cross_port_export_pkg_config

# Install into both the sysroot (so the next library in the chain can find it)
# and the staged root (so it reaches the image).
install_both() {
    local build_dir="$1" kind="$2"
    case "$kind" in
        meson)
            DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$build_dir" --no-rebuild
            DESTDIR="$ROOT_DIR" meson install -C "$build_dir" --no-rebuild
            ;;
        cmake)
            DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$build_dir"
            DESTDIR="$ROOT_DIR" cmake --install "$build_dir"
            ;;
    esac
}

# --- zlib ----------------------------------------------------------------
# Its configure is hand-written, not autotools, and takes the compiler through
# the environment rather than --host.
mkdir -p "$BUILD/zlib"
(
    cd "$BUILD/zlib"
    env CC="$CROSS_CC" AR="$CROSS_AR" CFLAGS="-O2 -fPIC" \
        bash "$ZLIB_SOURCE/configure" --prefix=/usr --libdir=/usr/lib
    make -j"$JOBS"
    make install DESTDIR="$GRAPHICS_SYSROOT"
    make install DESTDIR="$ROOT_DIR"
)
[[ -f "$GRAPHICS_SYSROOT/usr/include/zlib.h" ]] || cross_port_fail "zlib headers were not installed"

# --- libpng --------------------------------------------------------------
cmake -S "$LIBPNG_SOURCE" -B "$BUILD/libpng" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-O2 -fPIC" \
    -DPNG_SHARED=ON -DPNG_STATIC=OFF \
    -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_EXECUTABLES=OFF \
    -DPNG_HARDWARE_OPTIMIZATIONS=OFF \
    -DZLIB_ROOT="$GRAPHICS_SYSROOT/usr" \
    -DZLIB_INCLUDE_DIR="$GRAPHICS_SYSROOT/usr/include" \
    -DZLIB_LIBRARY="$GRAPHICS_SYSROOT/usr/lib/libz.so"
cmake --build "$BUILD/libpng" --parallel "$JOBS"
install_both "$BUILD/libpng" cmake
[[ -f "$GRAPHICS_SYSROOT/usr/include/png.h" ]] || cross_port_fail "libpng headers were not installed"

# --- freetype ------------------------------------------------------------
# harfbuzz and brotli are for advanced shaping and woff2, neither of which a
# compositor drawing frame decorations needs.
meson setup "$BUILD/freetype" "$FREETYPE_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dharfbuzz=disabled -Dbrotli=disabled -Dbzip2=disabled -Dtests=disabled
meson compile -C "$BUILD/freetype" -j "$JOBS"
install_both "$BUILD/freetype" meson
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/freetype2.pc" ]] || \
    cross_port_fail "freetype2.pc was not installed"

# --- expat ---------------------------------------------------------------
# Only fontconfig wants it, and only to read its own configuration.
cmake -S "$EXPAT_SOURCE" -B "$BUILD/expat" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF \
    -DEXPAT_SHARED_LIBS=ON
cmake --build "$BUILD/expat" --parallel "$JOBS"
install_both "$BUILD/expat" cmake

# Read the version back from what was installed: expat.h writes it as
# `#  define`, and the .pc file is what fontconfig's own check consults.
expat_version=$(sed -n 's/^Version:[[:space:]]*//p' \
    "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/expat.pc" 2>/dev/null || true)
[[ "$expat_version" == "$EXPECTED_EXPAT_VERSION" ]] || \
    cross_port_fail "expected expat $EXPECTED_EXPAT_VERSION, found ${expat_version:-unknown}"

# --- the font ------------------------------------------------------------
# Installed before fontconfig is configured so the directory it is pointed at is
# not empty, and so the licence travels with the files.
FONT_DIR="$ROOT_DIR/usr/share/fonts/jetbrains-mono"
mkdir -p "$FONT_DIR"
for face in Regular Bold Italic BoldItalic; do
    face_file="$FONT_SOURCE/fonts/ttf/JetBrainsMono-$face.ttf"
    [[ -f "$face_file" ]] || cross_port_fail "JetBrains Mono $face is missing"
    install -m 0644 "$face_file" "$FONT_DIR/"
done
install -m 0644 "$FONT_SOURCE/OFL.txt" "$FONT_DIR/LICENSE.txt"

# --- fontconfig ----------------------------------------------------------
# cache-build is off because it would run the freshly cross-built fc-cache on
# the host. With no cache fontconfig scans the directory on first use, which for
# four files is not worth solving.
fontconfig_version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$FONTCONFIG_SOURCE/meson.build" | head -n1)
[[ "$fontconfig_version" == "$EXPECTED_FONTCONFIG_VERSION" ]] || \
    cross_port_fail "expected fontconfig $EXPECTED_FONTCONFIG_VERSION, found ${fontconfig_version:-unknown}"

meson setup "$BUILD/fontconfig" "$FONTCONFIG_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --sysconfdir=/etc --localstatedir=/var \
    --buildtype=release --default-library=shared \
    -Dxml-backend=expat \
    -Dcache-build=disabled \
    -Ddoc=disabled \
    -Dnls=disabled \
    -Diconv=disabled \
    -Dfontations=disabled \
    -Dtests=disabled \
    -Dtests-external-fonts=disabled \
    -Dtools=enabled \
    -Ddefault-fonts-dirs=/usr/share/fonts \
    -Dadditional-fonts-dirs=/usr/local/share/fonts
meson compile -C "$BUILD/fontconfig" -j "$JOBS"
install_both "$BUILD/fontconfig" meson
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/fontconfig.pc" ]] || \
    cross_port_fail "fontconfig.pc was not installed"
[[ -f "$ROOT_DIR/etc/fonts/fonts.conf" ]] || \
    cross_port_fail "fontconfig's base configuration was not installed"
# fontconfig writes its cache here at runtime; the directory has to exist.
mkdir -p "$ROOT_DIR/var/cache/fontconfig"

# --- cairo ---------------------------------------------------------------
meson setup "$BUILD/cairo" "$CAIRO_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dfreetype=enabled \
    -Dpng=enabled \
    -Dzlib=enabled \
    -Dfontconfig=enabled \
    -Dxlib=disabled \
    -Dxcb=disabled \
    -Dquartz=disabled \
    -Dtee=disabled \
    -Dglib=disabled \
    -Dspectre=disabled \
    -Dsymbol-lookup=disabled \
    -Dtests=disabled \
    -Dgtk2-utils=disabled
meson compile -C "$BUILD/cairo" -j "$JOBS"
install_both "$BUILD/cairo" meson

[[ -f "$GRAPHICS_SYSROOT/usr/include/cairo/cairo.h" ]] || \
    cross_port_fail "cairo headers were not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/cairo.pc" ]] || \
    cross_port_fail "cairo.pc was not installed into the graphics sysroot"

for spec in "libz.so.1:libz.so.1" "libpng16.so.16:libpng16.so.16" \
            "libfreetype.so.6:libfreetype.so.6" "libexpat.so.1:libexpat.so.1" \
            "libfontconfig.so.1:libfontconfig.so.1" "libcairo.so.2:libcairo.so.2"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done

# usr/share is *not* wholesale removed here, unlike the other ports: it now
# holds the fonts themselves and fontconfig's conf.avail, which the symlinks
# under /etc/fonts/conf.d point at. usr/bin keeps fc-match and fc-list, which
# are how a font problem gets diagnosed on the machine itself.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/man" \
       "$ROOT_DIR/usr/share/doc" "$ROOT_DIR/usr/share/gettext" \
       "$ROOT_DIR/usr/share/xml"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'cairo %s stack (zlib, libpng, freetype, expat, fontconfig, JetBrains Mono) staged at %s (%s)\n' \
    "$cairo_version" "$ROOT_DIR" "$size"
