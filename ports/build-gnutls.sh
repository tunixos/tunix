#!/usr/bin/env bash
set -euo pipefail

# Build gnutls for Tunix -- the TLS implementation behind glib-networking, and
# so behind every https:// the browser loads.
#
# From a release tarball rather than the git tree, and for a different reason
# than the gmp port's: gnutls does have a git repository, but bootstrapping it
# imports gnulib *and* checks out five unrelated submodules first, two of which
# are full copies of openssl and nettle. The tarball already carries the
# gnulib import and a generated configure. Its SHA-256 is checked against the
# value published for the release, which two independent mirrors agree on.
#
# What is deliberately off, and why:
#
#   p11-kit         no PKCS#11 tokens on the image; without this gnutls would
#                   also want a system p11-kit trust module at runtime.
#   idn             libidn2 is not ported; non-ASCII hostnames lose their
#                   punycode conversion, which is the same trade libpsl made.
#   tpm, tpm2       no TPM in the guest.
#   dane            needs unbound, a DNS resolver library nothing else wants.
#   tools, tests    certtool and friends pull in libopts and datefudge.
#   nls             musl has no gettext runtime.
#   compression     the record-layer compression gnutls can do is a legacy
#                   feature no modern peer negotiates.
#
# The trust store is the one the image already ships for mbedTLS, so https-get,
# curl and the browser all verify against the same 119 roots.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for glib-networking
#   $OUT/gnutls-root/usr/lib                  libgnutls

PORT_NAME=gnutls
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

GNUTLS_VERSION=3.8.10
GNUTLS_SHA256=db7fab7cce791e7727ebbef2334301c821d79a550ec55c9ef096b610b03eb6b7
GNUTLS_SERIES=${GNUTLS_VERSION%.*}
GNUTLS_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v$GNUTLS_SERIES/gnutls-$GNUTLS_VERSION.tar.xz"

# The CA bundle the image installs, and what gnutls compiles in as its default
# trust store. Certificate verification finds nothing without it.
TRUST_STORE=/etc/ssl/cert.pem

CACHE=${GNUTLS_CACHE:-/var/tmp/tunix-gnutls}
TARBALL="$CACHE/gnutls-$GNUTLS_VERSION.tar.xz"
SOURCE="$CACHE/gnutls-$GNUTLS_VERSION"
BUILD=${GNUTLS_BUILD_DIR:-/var/tmp/tunix-gnutls-build}
ROOT_DIR="$OUT/gnutls-root"

cross_port_require_toolchain
cross_port_require_tools make curl sha256sum tar pkg-config "$READELF"

for module in nettle hogweed libtasn1; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

mkdir -p "$CACHE"
if [[ ! -f "$TARBALL" ]]; then
    curl -sSL --max-time 600 -o "$TARBALL.partial" "$GNUTLS_URL" || \
        cross_port_fail "could not download $GNUTLS_URL"
    mv "$TARBALL.partial" "$TARBALL"
fi

observed=$(sha256sum "$TARBALL" | cut -d' ' -f1)
[[ "$observed" == "$GNUTLS_SHA256" ]] || cross_port_fail \
    "gnutls-$GNUTLS_VERSION.tar.xz has SHA-256 $observed, expected $GNUTLS_SHA256"

rm -rf "$SOURCE" "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"
tar -xf "$TARBALL" -C "$CACHE"
[[ -x "$SOURCE/configure" ]] || cross_port_fail "the tarball did not unpack a configure script"

cross_port_export_pkg_config
cross_port_autotools_setup

cross_port_configure "$SOURCE" "$BUILD" \
    --with-included-unistring \
    --with-default-trust-store-file="$TRUST_STORE" \
    --without-p11-kit \
    --without-idn \
    --without-tpm \
    --without-tpm2 \
    --without-zlib \
    --without-brotli \
    --without-zstd \
    --disable-libdane \
    --disable-tools \
    --disable-tests \
    --disable-doc \
    --disable-gtk-doc \
    --disable-nls \
    --disable-cxx \
    --disable-rpath \
    --disable-guile

make -C "$BUILD" -j "$JOBS"
make -C "$BUILD" DESTDIR="$GRAPHICS_SYSROOT" install > /dev/null
make -C "$BUILD" DESTDIR="$ROOT_DIR" install > /dev/null

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/gnutls.pc" ]] || \
    cross_port_fail "gnutls.pc was not installed"

library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libgnutls.so.30*' -print -quit)
[[ -n "$library" ]] || cross_port_fail "libgnutls.so.30 was not installed"
cross_port_check_library "$library" libgnutls.so.30

# The compiled-in trust store path is the whole reason certificate verification
# works on the image; a configure that quietly ignored the flag would only show
# up as every https page failing with "unknown CA".
#
# Read into a variable rather than piping into grep: under `set -o pipefail` a
# grep that matches early kills readelf with SIGPIPE, and the pipeline then
# reports the failure of the very check that just succeeded.
rodata=$("$READELF" -p .rodata "$library")
case "$rodata" in
    *"$TRUST_STORE"*) ;;
    *) cross_port_fail "libgnutls does not carry the $TRUST_STORE trust store path" ;;
esac

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/bin" \
       "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/nettle-root" "$OUT/gmp-root" \
    "$OUT/libtasn1-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'gnutls %s staged at %s (%s)\n' "$GNUTLS_VERSION" "$ROOT_DIR" "$size"
