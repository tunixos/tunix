#!/usr/bin/env bash
set -euo pipefail

# Build libwebp for Tunix -- WebCore decodes .webp images with it, animated
# ones through libwebpdemux. Encoders and the cwebp/dwebp tool set stay off;
# the image only ever decodes.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for webkit
#   $OUT/libwebp-root/usr/lib                 libwebp, libwebpdemux, libsharpyuv

PORT_NAME=libwebp
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

WEBP_SOURCE="$ROOT/ports/src/libwebp"

BUILD="$OUT/libwebp-build"
ROOT_DIR="$OUT/libwebp-root"
CMAKE_FILE="$OUT/tunix-cmake-cross.cmake"

EXPECTED_WEBP_VERSION=1.6.0

[[ -f "$WEBP_SOURCE/CMakeLists.txt" ]] || cross_port_fail \
    "missing $WEBP_SOURCE/CMakeLists.txt; run git submodule update --init ports/src/libwebp"

cross_port_require_toolchain
cross_port_require_tools cmake "$READELF"

webp_version=$(sed -n 's/^AC_INIT(\[libwebp\], \[\([0-9.]*\)\].*/\1/p' \
    "$WEBP_SOURCE/configure.ac" | head -n1)
[[ "${webp_version:-}" == "$EXPECTED_WEBP_VERSION" ]] || \
    cross_port_fail "expected libwebp $EXPECTED_WEBP_VERSION, found ${webp_version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_cmake_toolchain "$CMAKE_FILE"
cross_port_export_pkg_config

cmake -S "$WEBP_SOURCE" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-O2 -fPIC" \
    -DBUILD_SHARED_LIBS=ON \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
cmake --build "$BUILD" --parallel "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$BUILD"
DESTDIR="$ROOT_DIR" cmake --install "$BUILD"

for pc in libwebp libwebpdemux; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed"
done

for name in libwebp libwebpdemux libsharpyuv; do
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name.so.*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    soname=$("$READELF" -d "$library" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')
    cross_port_check_library "$library" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libwebp %s staged at %s (%s)\n' "$webp_version" "$ROOT_DIR" "$size"
