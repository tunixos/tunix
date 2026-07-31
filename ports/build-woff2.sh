#!/usr/bin/env bash
set -euo pipefail

# Build brotli and woff2 for Tunix. Web fonts arrive as WOFF2, whose payload
# is brotli-compressed; WebKit hard-requires the decoder side of both.
# brotli's encoder libraries come along in the same build (they are small and
# upstream does not split them), but only the decoder is load-bearing.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for webkit
#   $OUT/woff2-root/usr/lib                   libbrotli*, libwoff2*

PORT_NAME=woff2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

BROTLI_SOURCE="$ROOT/ports/src/brotli"
WOFF2_SOURCE="$ROOT/ports/src/woff2"
PATCH_DIR="$ROOT/ports/src/patches/woff2"

BUILD="$OUT/woff2-build"
ROOT_DIR="$OUT/woff2-root"
CMAKE_FILE="$OUT/tunix-cmake-cross.cmake"

for source in "$BROTLI_SOURCE/CMakeLists.txt" "$WOFF2_SOURCE/CMakeLists.txt"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done

cross_port_require_toolchain
cross_port_require_tools cmake pkg-config "$READELF"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_cmake_toolchain "$CMAKE_FILE"
cross_port_export_pkg_config

# --- brotli --------------------------------------------------------------
# brotli detects emscripten by compiling a TU that is *empty* unless
# __EMSCRIPTEN__ is defined; with the toolchain's try-compile type of
# STATIC_LIBRARY an empty TU "compiles", the check succeeds, and brotli
# silently switches itself to static libraries. Restore executable
# try-compiles for this project -- the cross gcc links fine, it just
# cannot run the result, and nothing here runs it.
cmake -S "$BROTLI_SOURCE" -B "$BUILD/brotli" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=EXECUTABLE \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-O2 -fPIC" \
    -DBUILD_SHARED_LIBS=ON \
    -DBROTLI_DISABLE_TESTS=ON
cmake --build "$BUILD/brotli" --parallel "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$BUILD/brotli"
DESTDIR="$ROOT_DIR" cmake --install "$BUILD/brotli"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libbrotlidec.pc" ]] || \
    cross_port_fail "libbrotlidec.pc was not installed"

# --- woff2 ---------------------------------------------------------------
# Patch a copy, never ports/src (missing <cstdint> under GCC 13+); same
# discipline as weston and pango.
rm -rf "$BUILD/woff2-src"
mkdir -p "$BUILD/woff2-src"
tar -C "$WOFF2_SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/woff2-src" -xf -
patches=("$PATCH_DIR"/*.patch)
[[ -e "${patches[0]}" ]] || cross_port_fail "no patches found in $PATCH_DIR"
for patch_file in "${patches[@]}"; do
    patch -p1 -d "$BUILD/woff2-src" --fuzz=0 --forward < "$patch_file" || \
        cross_port_fail "failed to apply $(basename "$patch_file")"
done

# woff2 locates brotli with pkg-config; point it at the sysroot explicitly,
# since the CMake toolchain file alone does not confine pkg-config.
PKG_CONFIG_LIBDIR="$GRAPHICS_SYSROOT/usr/lib/pkgconfig" \
PKG_CONFIG_SYSROOT_DIR="$GRAPHICS_SYSROOT" \
cmake -S "$BUILD/woff2-src" -B "$BUILD/woff2" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_CXX_FLAGS="-O2 -fPIC" \
    -DBUILD_SHARED_LIBS=ON
cmake --build "$BUILD/woff2" --parallel "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$BUILD/woff2"
DESTDIR="$ROOT_DIR" cmake --install "$BUILD/woff2"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libwoff2dec.pc" ]] || \
    cross_port_fail "libwoff2dec.pc was not installed"

for name in libbrotlicommon libbrotlidec libbrotlienc libwoff2common libwoff2dec; do
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name.so.*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    soname=$("$READELF" -d "$library" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')
    cross_port_check_library "$library" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete
# libwoff2enc converts fonts *to* woff2; nothing on the image does that.
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name 'libwoff2enc*' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/mesa-root" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'brotli + woff2 staged at %s (%s)\n' "$ROOT_DIR" "$size"
