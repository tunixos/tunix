#!/usr/bin/env bash
set -euo pipefail

# Build ICU for Tunix. First real dependency of the WebKitGTK chain: WebCore
# and JavaScriptCore lean on it for every string, collation and break
# iterator, and harfbuzz gains its icu shaper from it later.
#
# ICU cross-compiles in two passes by design: the build generates its data
# library with tools it has just compiled, so a *host* build runs first and
# the cross pass borrows those tools via --with-cross-build. The host half
# lives in /var/tmp (native ext4, see ports/build-musl-cross.sh for the same
# trick) because it is throwaway and drvfs is slow.
#
# Choices that are load-bearing:
#
#   --with-data-packaging=library   the ~30 MB data set becomes libicudata.so;
#                                   no ICU_DATA environment or dat file to get
#                                   wrong at runtime.
#   --disable-extras/tools kept ON  the cross build needs its own icupkg and
#                                   pkgdata to assemble libicudata; only
#                                   extras (uconv) and tests are dropped.
#   renaming stays ON               the default; every consumer compiles
#                                   against the same versioned symbols.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for the consumers
#   $OUT/icu-root/usr/lib                     the shared libraries

PORT_NAME=icu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

ICU_SOURCE="$ROOT/ports/src/icu/icu4c/source"

BUILD=${ICU_BUILD_DIR:-/var/tmp/tunix-icu-build}
ROOT_DIR="$OUT/icu-root"

EXPECTED_ICU_VERSION=77.1

[[ -f "$ICU_SOURCE/configure" ]] || cross_port_fail \
    "missing $ICU_SOURCE/configure; run git submodule update --init ports/src/icu"

cross_port_require_toolchain
cross_port_require_tools make gcc g++ pkg-config "$READELF"

icu_version=$(sed -n 's/^#define U_ICU_VERSION "\([0-9.]*\)".*/\1/p' \
    "$ICU_SOURCE/common/unicode/uvernum.h" | head -n1)
[[ "$icu_version" == "$EXPECTED_ICU_VERSION" ]] || \
    cross_port_fail "expected icu $EXPECTED_ICU_VERSION, found ${icu_version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/host" "$BUILD/cross" "$ROOT_DIR"

cross_port_export_pkg_config

# --- host pass -----------------------------------------------------------
# Only exists to hand its bin/ and lib/ to the cross pass; never installed.
(
    cd "$BUILD/host"
    CC=gcc CXX=g++ "$ICU_SOURCE/configure" \
        --prefix=/usr \
        --disable-shared --enable-static \
        --disable-extras --disable-tests --disable-samples \
        > configure.log
    make -j "$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
)

# --- cross pass ----------------------------------------------------------
(
    cd "$BUILD/cross"
    CC="$CROSS_CC" CXX="$CROSS_CXX" \
    CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
    "$ICU_SOURCE/configure" \
        --host="$CROSS_TARGET" \
        --with-cross-build="$BUILD/host" \
        --prefix=/usr \
        --enable-shared --disable-static \
        --with-data-packaging=library \
        --disable-extras --disable-tests --disable-samples \
        > configure.log
    make -j "$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
)

make -C "$BUILD/cross" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
make -C "$BUILD/cross" install DESTDIR="$ROOT_DIR" > /dev/null

for pc in icu-uc icu-i18n icu-io; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed into the graphics sysroot"
done

major=${EXPECTED_ICU_VERSION%%.*}
for name in libicudata libicuuc libicui18n libicuio; do
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name.so.*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$name.so.$major"
done

# The image only needs the libraries: no headers, no icu-config, no
# makeconv/genbrk tool set, no static data archives. libicutu/libicutest
# exist for ICU's own tools and test suite.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/sbin" \
       "$ROOT_DIR/usr/share" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/lib/icu"
find "$ROOT_DIR/usr/lib" -maxdepth 1 \( -name 'libicutu*' -o -name 'libicutest*' \) -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libicuuc is C++; libstdc++/libgcc_s ship with mesa-root already, and
# libdrm-root closes over mesa's own winsys libraries.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/mesa-root" "$OUT/libdrm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'icu %s staged at %s (%s)\n' "$icu_version" "$ROOT_DIR" "$size"
