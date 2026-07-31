#!/usr/bin/env bash
set -euo pipefail

# Build libgpg-error and libgcrypt for Tunix. WebKit's crypto sits on
# libgcrypt: WebCrypto when it is enabled, and PAL's hashes either way.
#
# Both are autotools projects built from git, so autogen.sh (autoreconf plus
# the gnupg version machinery) runs on the host first. Cross-compiling
# libgpg-error is the classically fiddly part -- it needs a pre-generated
# lock-obj header for the target triplet, which upstream ships for musl.
# libgcrypt then locates gpg-error through gpgrt-config, which honours a
# SYSROOT environment variable for exactly this staged-prefix arrangement.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for webkit
#   $OUT/libgcrypt-root/usr/lib               libgpg-error, libgcrypt

PORT_NAME=libgcrypt
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

GPG_ERROR_SOURCE="$ROOT/ports/src/libgpg-error"
GCRYPT_SOURCE="$ROOT/ports/src/libgcrypt"

BUILD=${GCRYPT_BUILD_DIR:-/var/tmp/tunix-libgcrypt-build}
ROOT_DIR="$OUT/libgcrypt-root"

for source in "$GPG_ERROR_SOURCE/configure.ac" "$GCRYPT_SOURCE/configure.ac"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done

cross_port_require_toolchain
cross_port_require_tools make autoreconf "$READELF"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/gpg-error" "$BUILD/gcrypt" "$ROOT_DIR"

cross_port_export_pkg_config

# --- libgpg-error --------------------------------------------------------
# autogen.sh regenerates the build system in the source tree; the actual
# configure runs out of tree. --force gets past a previous run's stamps.
(cd "$GPG_ERROR_SOURCE" && ./autogen.sh > "$BUILD/gpg-error/autogen.log" 2>&1) || \
    { tail -30 "$BUILD/gpg-error/autogen.log"; exit 1; }
(
    cd "$BUILD/gpg-error"
    CC="$CROSS_CC" CFLAGS="-O2 -fPIC" \
    "$GPG_ERROR_SOURCE/configure" \
        --host="$CROSS_TARGET" \
        --prefix=/usr \
        --enable-shared --disable-static \
        --disable-doc --disable-tests --disable-nls \
        --enable-install-gpg-error-config \
        > configure.log
    make -j "$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
)
make -C "$BUILD/gpg-error" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
make -C "$BUILD/gpg-error" install DESTDIR="$ROOT_DIR" > /dev/null
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/gpg-error.pc" ]] || \
    cross_port_fail "gpg-error.pc was not installed"
# A staged .la records libdir=/usr/lib, so any later libtool link follows it
# to the *host's* libgpg-error. Kill them in the sysroot on sight.
rm -f "$GRAPHICS_SYSROOT/usr/lib/libgpg-error.la"

# --- libgcrypt -----------------------------------------------------------
(cd "$GCRYPT_SOURCE" && ./autogen.sh > "$BUILD/gcrypt/autogen.log" 2>&1) || \
    { tail -30 "$BUILD/gcrypt/autogen.log"; exit 1; }
(
    cd "$BUILD/gcrypt"
    SYSROOT="$GRAPHICS_SYSROOT" \
    GPGRT_CONFIG="$GRAPHICS_SYSROOT/usr/bin/gpgrt-config" \
    CC="$CROSS_CC" \
    CFLAGS="-O2 -fPIC -I$GRAPHICS_SYSROOT/usr/include" \
    LDFLAGS="-L$GRAPHICS_SYSROOT/usr/lib -Wl,-rpath-link,$GRAPHICS_SYSROOT/usr/lib" \
    "$GCRYPT_SOURCE/configure" \
        --host="$CROSS_TARGET" \
        --prefix=/usr \
        --enable-shared --disable-static \
        --disable-doc \
        --with-libgpg-error-prefix="$GRAPHICS_SYSROOT/usr" \
        > configure.log
    make -j "$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
)
make -C "$BUILD/gcrypt" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
make -C "$BUILD/gcrypt" install DESTDIR="$ROOT_DIR" > /dev/null
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libgcrypt.pc" ]] || \
    cross_port_fail "libgcrypt.pc was not installed"
rm -f "$GRAPHICS_SYSROOT/usr/lib/libgcrypt.la"

for name in libgpg-error libgcrypt; do
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name.so.*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    soname=$("$READELF" -d "$library" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')
    cross_port_check_library "$library" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/bin" \
       "$ROOT_DIR/usr/share" "$ROOT_DIR/usr/lib/cmake"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -o -name '*.la' | xargs -r rm -f
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libgpg-error + libgcrypt staged at %s (%s)\n' "$ROOT_DIR" "$size"
