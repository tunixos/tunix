#!/usr/bin/env bash
set -euo pipefail

# Build GMP for Tunix -- the bignum library under nettle's public-key code,
# which gnutls needs for RSA, DH and the elliptic curves.
#
# This is the one port that builds from a release tarball rather than a
# submodule: GMP's upstream is a Mercurial repository, so there is no git URL
# to point a submodule at. The tarball is fetched once into a cache and checked
# against the SHA-256 the GNU project publishes, which is the property the
# submodule commit would otherwise have given us.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers for nettle and gnutls
#   $OUT/gmp-root/usr/lib                     libgmp

PORT_NAME=gmp
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

GMP_VERSION=6.3.0
GMP_SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
GMP_URL="https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"

CACHE=${GMP_CACHE:-/var/tmp/tunix-gmp}
TARBALL="$CACHE/gmp-$GMP_VERSION.tar.xz"
SOURCE="$CACHE/gmp-$GMP_VERSION"
BUILD=${GMP_BUILD_DIR:-/var/tmp/tunix-gmp-build}
ROOT_DIR="$OUT/gmp-root"

cross_port_require_toolchain
# m4 is not optional here: GMP's assembly is generated from .asm sources by m4.
cross_port_require_tools make m4 curl sha256sum tar "$READELF"

mkdir -p "$CACHE"
if [[ ! -f "$TARBALL" ]]; then
    curl -sSL --max-time 600 -o "$TARBALL.partial" "$GMP_URL" || \
        cross_port_fail "could not download $GMP_URL"
    mv "$TARBALL.partial" "$TARBALL"
fi

observed=$(sha256sum "$TARBALL" | cut -d' ' -f1)
[[ "$observed" == "$GMP_SHA256" ]] || cross_port_fail \
    "gmp-$GMP_VERSION.tar.xz has SHA-256 $observed, expected $GMP_SHA256"

rm -rf "$SOURCE" "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"
tar -xf "$TARBALL" -C "$CACHE"
[[ -x "$SOURCE/configure" ]] || cross_port_fail "the tarball did not unpack a configure script"

cross_port_export_pkg_config
cross_port_autotools_setup
# GMP's compiler probes call a K&R `void g(){}` with six arguments, which under
# GCC 14's C23 default is an error rather than a warning -- so configure decides
# the compiler is broken and gives up. The library itself predates C23; the same
# -std the make and git ports use restores the reading it was written against.
CFLAGS="$CFLAGS -std=gnu17"
export CFLAGS

# --enable-cxx would build libgmpxx, which nothing on the image links.
# --disable-assembly is deliberately *not* passed: the x86_64 assembly is the
# reason GMP is worth having, and the cross assembler handles it.
cross_port_configure "$SOURCE" "$BUILD" --enable-cxx=no

make -C "$BUILD" -j "$JOBS"
make -C "$BUILD" DESTDIR="$GRAPHICS_SYSROOT" install > /dev/null
make -C "$BUILD" DESTDIR="$ROOT_DIR" install > /dev/null

[[ -f "$GRAPHICS_SYSROOT/usr/include/gmp.h" ]] || cross_port_fail "gmp.h was not installed"
cross_port_check_library "$(readlink -f "$ROOT_DIR/usr/lib/libgmp.so.10")" libgmp.so.10

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.la' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'gmp %s staged at %s (%s)\n' "$GMP_VERSION" "$ROOT_DIR" "$size"
