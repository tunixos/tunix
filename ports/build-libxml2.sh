#!/usr/bin/env bash
set -euo pipefail

# Build libxml2 and libxslt for Tunix. WebCore parses XML/XSLT with them, and
# libxkbcommon's xkbregistry links libxml2 alone.
#
# libxml2 uses its meson port; libxslt has no meson, so it rides the CMake
# toolchain file. Everything optional is off -- notably icu, which WebKit wants
# libxml2 built *without* because it does its own unicode handling.

PORT_NAME=libxml2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

XML2_SOURCE="$ROOT/ports/src/libxml2"
XSLT_SOURCE="$ROOT/ports/src/libxslt"

BUILD="$OUT/libxml2-build"
ROOT_DIR="$OUT/libxml2-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"
CMAKE_FILE="$OUT/tunix-cmake-cross.cmake"

EXPECTED_XML2_VERSION=2.14.6
EXPECTED_XSLT_VERSION=1.1.45

for source in "$XML2_SOURCE/meson.build" "$XSLT_SOURCE/CMakeLists.txt"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done

cross_port_require_toolchain
cross_port_require_tools meson ninja cmake pkg-config "$READELF"

xml2_version=$(tr -d '[:space:]' < "$XML2_SOURCE/VERSION")
[[ "$xml2_version" == "$EXPECTED_XML2_VERSION" ]] || \
    cross_port_fail "expected libxml2 $EXPECTED_XML2_VERSION, found ${xml2_version:-unknown}"

xslt_version=$(sed -n 's/^m4_define(\[\(MAJOR\|MINOR\|MICRO\)_VERSION\],[ \t]*\[\([0-9]*\)\]).*/\2/p' \
    "$XSLT_SOURCE/configure.ac" | paste -sd. -)
[[ "$xslt_version" == "$EXPECTED_XSLT_VERSION" ]] || \
    cross_port_fail "expected libxslt $EXPECTED_XSLT_VERSION, found ${xslt_version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_write_cmake_toolchain "$CMAKE_FILE"
cross_port_export_pkg_config

# --- libxml2 -------------------------------------------------------------
meson setup "$BUILD/libxml2" "$XML2_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dzlib=enabled \
    -Dicu=disabled -Dlzma=disabled -Dhttp=disabled -Dpython=disabled \
    -Dreadline=disabled -Dhistory=disabled
meson compile -C "$BUILD/libxml2" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/libxml2" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/libxml2" --no-rebuild
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libxml-2.0.pc" ]] || \
    cross_port_fail "libxml-2.0.pc was not installed"

# --- libxslt -------------------------------------------------------------
# CMake finds libxml2 through the sysroot (CMAKE_FIND_ROOT_PATH); the
# pkg-config confinement keeps its hint pass off the build host's libxml2.
# Crypto would drag in libgcrypt for EXSLT functions nothing uses.
PKG_CONFIG_LIBDIR="$GRAPHICS_SYSROOT/usr/lib/pkgconfig" \
PKG_CONFIG_SYSROOT_DIR="$GRAPHICS_SYSROOT" \
cmake -S "$XSLT_SOURCE" -B "$BUILD/libxslt" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-O2 -fPIC" \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBXSLT_WITH_PYTHON=OFF -DLIBXSLT_WITH_CRYPTO=OFF \
    -DLIBXSLT_WITH_TESTS=OFF -DLIBXSLT_WITH_DEBUGGER=OFF \
    -DLIBXSLT_WITH_XSLT_DEBUG=OFF -DLIBXSLT_WITH_PROFILER=OFF \
    -DLIBXSLT_WITH_MODULES=OFF -DLIBXSLT_WITH_PROGRAMS=OFF
cmake --build "$BUILD/libxslt" --parallel "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$BUILD/libxslt"
DESTDIR="$ROOT_DIR" cmake --install "$BUILD/libxslt"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libxslt.pc" ]] || \
    cross_port_fail "libxslt.pc was not installed"

for spec in "libxml2.so:libxml2" "libxslt.so:libxslt" "libexslt.so:libexslt"; do
    name=${spec%%:*}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name.*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "${spec##*:} was not installed"
    soname=$("$READELF" -d "$library" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')
    cross_port_check_library "$library" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/share" \
       "$ROOT_DIR/usr/lib/xml2Conf.sh"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/cairo-root" "$OUT/libffi-root" \
    "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libxml2 %s + libxslt %s staged at %s (%s)\n' \
    "$xml2_version" "$xslt_version" "$ROOT_DIR" "$size"
