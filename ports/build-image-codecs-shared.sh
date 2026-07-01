#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
OUT=${OUT:-$ROOT/ports/out}
MUSL_SYSROOT="$OUT/musl-shared-sysroot"
MUSL_RUNTIME_ROOT="$OUT/musl-shared-root"
MUSL_CC="$MUSL_SYSROOT/usr/bin/musl-gcc"
DESKTOP_SYSROOT="$OUT/desktop-sysroot"
RUNTIME_ROOT="$OUT/image-codecs-shared-root"
ZLIB_SOURCE="$ROOT/ports/src/zlib"
LIBPNG_SOURCE="$ROOT/ports/src/libpng"
LIBJPEG_SOURCE="$ROOT/ports/src/libjpeg-turbo"
ZLIB_BUILD="$OUT/zlib-shared-build"
LIBPNG_BUILD="$OUT/libpng-shared-build"
LIBJPEG_BUILD="$OUT/libjpeg-turbo-shared-build"
TOOLCHAIN_FILE="$OUT/tunix-dynamic-toolchain.cmake"
TEST_SOURCE="$ROOT/tools/shared-image-codecs-test.c"
TEST_BINARY="$RUNTIME_ROOT/usr/bin/shared-image-codecs-test"
HOST_AR=${AR:-ar}
HOST_RANLIB=${RANLIB:-ranlib}
HOST_STRIP=${STRIP:-strip}
READELF=${READELF:-readelf}

EXPECTED_ZLIB_VERSION=1.3.2
EXPECTED_LIBPNG_VERSION=1.6.58
EXPECTED_LIBJPEG_VERSION=3.2.0

fail() {
    echo "build-image-codecs-shared: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "$2"
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 was not found"
}

copy_library_family() {
    local pattern=$1
    local found=0
    local item
    shopt -s nullglob
    for item in "$DESKTOP_SYSROOT/usr/lib"/$pattern; do
        cp -a "$item" "$RUNTIME_ROOT/usr/lib/"
        found=1
    done
    shopt -u nullglob
    [[ "$found" -eq 1 ]] || fail "no libraries matched $pattern"
}

require_file "$ZLIB_SOURCE/zlib.h" "missing zlib source"
require_file "$LIBPNG_SOURCE/png.h" "missing libpng source"
require_file "$LIBJPEG_SOURCE/CMakeLists.txt" "missing libjpeg-turbo source"
require_file "$TEST_SOURCE" "missing shared image codec test"
require_file "$ZLIB_SOURCE/configure" "zlib configure script is missing"
[[ -x "$MUSL_CC" ]] || fail "shared musl toolchain is missing; build dynamic runtime first"

for tool in cmake make "$HOST_AR" "$HOST_RANLIB" "$HOST_STRIP" "$READELF"; do
    require_tool "$tool"
done

loader_host=$(find "$MUSL_RUNTIME_ROOT/lib" -maxdepth 1 -name 'ld-musl-*.so.1' -print -quit)
[[ -n "$loader_host" ]] || fail "shared musl loader is missing"
loader_name=$(basename "$loader_host")

zlib_version=$(sed -n 's/^#define ZLIB_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' "$ZLIB_SOURCE/zlib.h" | head -n1)
libpng_version=$(sed -n 's/^#define PNG_LIBPNG_VER_STRING[[:space:]]*"\([^"]*\)".*/\1/p' "$LIBPNG_SOURCE/png.h" | head -n1)
libjpeg_version=$(sed -n 's/^set(VERSION[[:space:]]*\([^)]*\)).*/\1/p' "$LIBJPEG_SOURCE/CMakeLists.txt" | head -n1)
[[ "$zlib_version" == "$EXPECTED_ZLIB_VERSION" ]] || \
    fail "expected zlib $EXPECTED_ZLIB_VERSION, found ${zlib_version:-unknown}"
[[ "$libpng_version" == "$EXPECTED_LIBPNG_VERSION" ]] || \
    fail "expected libpng $EXPECTED_LIBPNG_VERSION, found ${libpng_version:-unknown}"
[[ "$libjpeg_version" == "$EXPECTED_LIBJPEG_VERSION" ]] || \
    fail "expected libjpeg-turbo $EXPECTED_LIBJPEG_VERSION, found ${libjpeg_version:-unknown}"

NO_AUTO_ATOMIC=""
probe=$(mktemp)
trap 'rm -f "$probe" "$probe.o"' EXIT
printf 'int tunix_probe;\n' > "$probe"
if "$MUSL_CC" -fno-link-libatomic -x c -c "$probe" -o "$probe.o" >/dev/null 2>&1; then
    NO_AUTO_ATOMIC="-fno-link-libatomic"
fi

COMMON_CFLAGS="-O2 -fPIC -fno-stack-protector $NO_AUTO_ATOMIC"
COMMON_LDFLAGS="-L$DESKTOP_SYSROOT/usr/lib -Wl,-rpath-link,$DESKTOP_SYSROOT/usr/lib $NO_AUTO_ATOMIC"

rm -rf "$ZLIB_BUILD" "$LIBPNG_BUILD" "$LIBJPEG_BUILD" \
       "$DESKTOP_SYSROOT" "$RUNTIME_ROOT"
mkdir -p "$ZLIB_BUILD" "$LIBPNG_BUILD" "$LIBJPEG_BUILD" \
         "$DESKTOP_SYSROOT" "$RUNTIME_ROOT/usr/bin" \
         "$RUNTIME_ROOT/usr/lib/pkgconfig" "$RUNTIME_ROOT/usr/share"

# Keep a complete development sysroot for every later graphics/desktop port.
cp -a "$MUSL_SYSROOT/." "$DESKTOP_SYSROOT/"

cat > "$TOOLCHAIN_FILE" <<EOF_TOOLCHAIN
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "$MUSL_CC")
set(CMAKE_AR "$HOST_AR")
set(CMAKE_RANLIB "$HOST_RANLIB")
set(CMAKE_FIND_ROOT_PATH "$DESKTOP_SYSROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF_TOOLCHAIN

(
    cd "$ZLIB_BUILD"
    env CC="$MUSL_CC" AR="$HOST_AR" RANLIB="$HOST_RANLIB" \
        CFLAGS="$COMMON_CFLAGS" LDFLAGS="$NO_AUTO_ATOMIC" \
        bash "$ZLIB_SOURCE/configure" \
            --prefix=/usr \
            --libdir=/usr/lib \
            --sharedlibdir=/usr/lib
    make -j"$JOBS"
    make install DESTDIR="$DESKTOP_SYSROOT"
)

require_file "$DESKTOP_SYSROOT/usr/include/zlib.h" "zlib headers were not installed"
require_file "$DESKTOP_SYSROOT/usr/lib/libz.a" "zlib static library was not installed"
require_file "$DESKTOP_SYSROOT/usr/lib/libz.so.$zlib_version" "zlib shared library was not installed"
[[ -L "$DESKTOP_SYSROOT/usr/lib/libz.so" ]] || fail "zlib linker symlink is missing"
[[ -L "$DESKTOP_SYSROOT/usr/lib/libz.so.1" ]] || fail "zlib SONAME symlink is missing"

cmake -S "$LIBPNG_SOURCE" -B "$LIBPNG_BUILD" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DPNG_SHARED=ON \
    -DPNG_STATIC=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF \
    -DPNG_EXECUTABLES=OFF \
    -DPNG_HARDWARE_OPTIMIZATIONS=OFF \
    -DZLIB_ROOT="$DESKTOP_SYSROOT/usr" \
    -DZLIB_INCLUDE_DIR="$DESKTOP_SYSROOT/usr/include" \
    -DZLIB_LIBRARY="$DESKTOP_SYSROOT/usr/lib/libz.so"
cmake --build "$LIBPNG_BUILD" --parallel "$JOBS"
DESTDIR="$DESKTOP_SYSROOT" cmake --install "$LIBPNG_BUILD"

require_file "$DESKTOP_SYSROOT/usr/include/png.h" "libpng headers were not installed"
png_shared=$(find "$DESKTOP_SYSROOT/usr/lib" -maxdepth 1 -type f -name 'libpng16.so.16.*' -print -quit)
[[ -n "$png_shared" ]] || fail "libpng shared library was not installed"
[[ -L "$DESKTOP_SYSROOT/usr/lib/libpng16.so" ]] || fail "libpng linker symlink is missing"
[[ -L "$DESKTOP_SYSROOT/usr/lib/libpng16.so.16" ]] || fail "libpng SONAME symlink is missing"

cmake -S "$LIBJPEG_SOURCE" -B "$LIBJPEG_BUILD" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=OFF \
    -DREQUIRE_SIMD=OFF \
    -DWITH_SIMD=OFF \
    -DWITH_TURBOJPEG=ON \
    -DWITH_TOOLS=OFF \
    -DWITH_TESTS=OFF
cmake --build "$LIBJPEG_BUILD" --parallel "$JOBS"
DESTDIR="$DESKTOP_SYSROOT" cmake --install "$LIBJPEG_BUILD"

require_file "$DESKTOP_SYSROOT/usr/include/jpeglib.h" "libjpeg headers were not installed"
require_file "$DESKTOP_SYSROOT/usr/include/turbojpeg.h" "TurboJPEG headers were not installed"
[[ -L "$DESKTOP_SYSROOT/usr/lib/libjpeg.so" ]] || fail "libjpeg linker symlink is missing"
[[ -L "$DESKTOP_SYSROOT/usr/lib/libturbojpeg.so" ]] || fail "TurboJPEG linker symlink is missing"

copy_library_family 'libz.so*'
copy_library_family 'libpng.so*'
copy_library_family 'libpng16.so*'
copy_library_family 'libjpeg.so*'
copy_library_family 'libturbojpeg.so*'

for pc in zlib.pc libpng.pc libpng16.pc libjpeg.pc libturbojpeg.pc; do
    require_file "$DESKTOP_SYSROOT/usr/lib/pkgconfig/$pc" "$pc was not installed"
    cp "$DESKTOP_SYSROOT/usr/lib/pkgconfig/$pc" "$RUNTIME_ROOT/usr/lib/pkgconfig/"
done

"$MUSL_CC" -std=c11 -Wall -Wextra -Werror -O2 -fPIE -pie \
    -fno-stack-protector $NO_AUTO_ATOMIC \
    -I"$DESKTOP_SYSROOT/usr/include" \
    "$TEST_SOURCE" \
    -L"$DESKTOP_SYSROOT/usr/lib" \
    -Wl,-rpath-link,"$DESKTOP_SYSROOT/usr/lib" \
    -Wl,--no-as-needed -lpng16 -ljpeg -lturbojpeg -lz -lm \
    -o "$TEST_BINARY"
chmod 0755 "$TEST_BINARY"

interp=$($READELF -l "$TEST_BINARY" | \
    sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
[[ "$interp" == "/lib/$loader_name" ]] || \
    fail "test binary has unexpected interpreter '${interp:-missing}'"

needed=$($READELF -d "$TEST_BINARY" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
for dependency in libpng16.so.16 libjpeg.so.62 libturbojpeg.so.0 libz.so.1 libc.so; do
    grep -Fxq "$dependency" <<<"$needed" || \
        fail "test binary is missing NEEDED $dependency"
done

for library in \
    "$DESKTOP_SYSROOT/usr/lib/libz.so.$zlib_version" \
    "$png_shared"; do
    $READELF -d "$library" | grep -q '(SONAME)' || \
        fail "$(basename "$library") has no SONAME"
done

library_path="$MUSL_RUNTIME_ROOT/lib:$RUNTIME_ROOT/usr/lib:$DESKTOP_SYSROOT/usr/lib"
"$loader_host" --library-path "$library_path" "$TEST_BINARY"

find "$RUNTIME_ROOT/usr/lib" -maxdepth 1 -type f -name '*.so*' \
    -exec "$HOST_STRIP" --strip-unneeded {} +
find "$RUNTIME_ROOT/usr/lib" -maxdepth 1 -type f -name '*.so*' \
    -exec chmod 0755 {} +
"$HOST_STRIP" --strip-all "$TEST_BINARY"

cat > "$RUNTIME_ROOT/usr/bin/shared-image-codecs-check" <<'EOF_CHECK'
#!/bin/sh
set -eu
/usr/bin/shared-image-codecs-test
printf '%s\n' 'shared-image-codecs-check: PASS'
EOF_CHECK
chmod 0755 "$RUNTIME_ROOT/usr/bin/shared-image-codecs-check"

mkdir -p "$RUNTIME_ROOT/usr/share/licenses/zlib" \
         "$RUNTIME_ROOT/usr/share/licenses/libpng" \
         "$RUNTIME_ROOT/usr/share/licenses/libjpeg-turbo"
[[ -f "$ZLIB_SOURCE/LICENSE" ]] && cp "$ZLIB_SOURCE/LICENSE" "$RUNTIME_ROOT/usr/share/licenses/zlib/"
[[ -f "$LIBPNG_SOURCE/LICENSE.md" ]] && cp "$LIBPNG_SOURCE/LICENSE.md" "$RUNTIME_ROOT/usr/share/licenses/libpng/"
[[ -f "$LIBJPEG_SOURCE/LICENSE.md" ]] && cp "$LIBJPEG_SOURCE/LICENSE.md" "$RUNTIME_ROOT/usr/share/licenses/libjpeg-turbo/"

printf '%s\n' \
    "zlib=$zlib_version" \
    "libpng=$libpng_version" \
    "libjpeg-turbo=$libjpeg_version" \
    > "$RUNTIME_ROOT/usr/share/tunix-shared-image-codecs.version"

printf 'Shared image codecs ready: zlib %s, libpng %s, libjpeg-turbo %s\n' \
    "$zlib_version" "$libpng_version" "$libjpeg_version"
