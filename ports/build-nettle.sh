#!/usr/bin/env bash
set -euo pipefail

# Build nettle for Tunix -- the cipher and public-key library gnutls is built
# on. Two libraries come out of it: libnettle (symmetric crypto and hashes,
# self-contained) and libhogweed (RSA, DSA and the elliptic curves, which is
# the half that needs GMP).
#
# The git tree ships no configure; .bootstrap is one line of autoconf, so it
# runs in the source tree the way the libtasn1 port's does, and the cross
# configure itself runs out of tree.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for gnutls
#   $OUT/nettle-root/usr/lib                  libnettle, libhogweed

PORT_NAME=nettle
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/nettle"
BUILD=${NETTLE_BUILD_DIR:-/var/tmp/tunix-nettle-build}
ROOT_DIR="$OUT/nettle-root"

EXPECTED_NETTLE_VERSION=3.10

[[ -f "$SOURCE/configure.ac" ]] || cross_port_fail \
    "missing $SOURCE/configure.ac; run git submodule update --init ports/src/nettle"

cross_port_require_toolchain
cross_port_require_tools make autoconf autoheader m4 "$READELF"

nettle_version=$(sed -n 's/^AC_INIT(\[nettle\], \[\([0-9.]*\)\].*/\1/p' "$SOURCE/configure.ac")
[[ "$nettle_version" == "$EXPECTED_NETTLE_VERSION" ]] || cross_port_fail \
    "expected nettle $EXPECTED_NETTLE_VERSION, found ${nettle_version:-unknown}"

[[ -f "$GRAPHICS_SYSROOT/usr/include/gmp.h" ]] || cross_port_fail \
    "gmp is not in the graphics sysroot; build the gmp port first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_export_pkg_config
cross_port_autotools_setup
# nettle carries a copy of getopt for its command-line tools, declared the K&R
# way; under GCC 14's C23 default `int getopt()` means "takes no arguments" and
# every call is an error. Same -std the gmp, make and git ports use.
CFLAGS="$CFLAGS -std=gnu17"
export CFLAGS

# nettle's .gitattributes marks the whole tree `text`, so a Windows checkout
# rewrites its shell scripts with CRLF and .bootstrap dies as "/bin/sh^M: bad
# interpreter" -- the same trap the libffi port documents.
if grep -q $'\r' "$SOURCE/.bootstrap"; then
    cross_port_fail "ports/src/nettle has CRLF line endings; re-check it out with core.eol=lf"
fi

[[ -x "$SOURCE/configure" ]] || ( cd "$SOURCE" && ./.bootstrap )

# --disable-openssl only drops the benchmark's comparison against OpenSSL; the
# library never links it. The x86_64 assembly stays on, and with it the runtime
# CPU dispatch (--enable-fat), so AES-NI is used where the guest CPU has it and
# the C fallback where it does not -- the image has to boot on both.
cross_port_configure "$SOURCE" "$BUILD" \
    --enable-fat \
    --disable-openssl \
    --disable-documentation

make -C "$BUILD" -j "$JOBS"
make -C "$BUILD" DESTDIR="$GRAPHICS_SYSROOT" install > /dev/null
make -C "$BUILD" DESTDIR="$ROOT_DIR" install > /dev/null

for module in nettle hogweed; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || \
        cross_port_fail "$module.pc was not installed"
done

for spec in "libnettle.so.8:libnettle.so.8" "libhogweed.so.6:libhogweed.so.6"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done

# nettle-hash and sexp-conv are developer tools; nothing on the image runs them.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/bin" \
       "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/gmp-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'nettle %s staged at %s (%s)\n' "$nettle_version" "$ROOT_DIR" "$size"
