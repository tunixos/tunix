#!/usr/bin/env bash
set -euo pipefail

# Build glib-networking for Tunix -- the piece that was missing for https.
#
# GIO does not implement TLS itself. g_tls_backend_get_default() looks up the
# "gio-tls-backend" extension point, which is empty unless a module in
# $libdir/gio/modules registers one; with nothing there libsoup reports "TLS
# support is not available" and WebKit fails every https:// load before a
# single packet goes out. This port supplies that module, on gnutls.
#
# The proxy modules come along in the same source tree: the environment one
# (http_proxy and friends) is worth having and costs nothing, libproxy and the
# GNOME one are configuration systems the image does not run.
#
# Nothing links these modules -- gio dlopens whatever it finds in the modules
# directory -- so the install must land there exactly, which is what the last
# check in this script is for.
#
# Output layout:
#   $OUT/glib-networking-root/usr/lib/gio/modules   libgiognutls, libgioenvironmentproxy

PORT_NAME=glib-networking
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/glib-networking"
BUILD="$OUT/glib-networking-build"
STAGE="$OUT/glib-networking-stage"
ROOT_DIR="$OUT/glib-networking-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_VERSION=2.80.1
MODULE_DIR=usr/lib/gio/modules

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init ports/src/glib-networking"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config python3 "$READELF"

version=$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || cross_port_fail \
    "expected glib-networking $EXPECTED_VERSION, found ${version:-unknown}"

for module in glib-2.0 gio-2.0 gnutls; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release \
    -Dgnutls=enabled \
    -Dopenssl=disabled \
    -Denvironment_proxy=enabled \
    -Dlibproxy=disabled \
    -Dgnome_proxy=disabled \
    -Dinstalled_tests=false
meson compile -C "$BUILD" -j "$JOBS"

# Installed into a staging directory rather than straight into the roots,
# because meson takes the module directory from gio-2.0.pc's `giomoduledir` and
# pkg-config -- told to rewrite this sysroot's prefixes -- hands back a path
# that already begins with the sysroot. DESTDIR then prepends it a second time
# and the modules land under a doubled path nothing will ever look in. Take the
# two modules out of wherever they landed and put them where gio looks.
rm -rf "$STAGE"
DESTDIR="$STAGE" meson install -C "$BUILD" --no-rebuild > /dev/null

for module in libgiognutls.so libgioenvironmentproxy.so; do
    built=$(find "$STAGE" -name "$module" -print -quit)
    [[ -n "$built" ]] || cross_port_fail "$module was not built"
    install -Dm755 "$built" "$ROOT_DIR/$MODULE_DIR/$module"
    # Into the sysroot as well, so a later port can *ask* whether GIO has TLS
    # rather than take it on trust; libsoup's tls_check is that question.
    install -Dm755 "$built" "$GRAPHICS_SYSROOT/$MODULE_DIR/$module"
done

library="$ROOT_DIR/$MODULE_DIR/libgiognutls.so"
# A module that dlopens but resolves its TLS calls somewhere else is not what
# this port is for. (Read into a variable: a `grep -q` that matches early would
# kill readelf with SIGPIPE, and `set -o pipefail` reports that as failure.)
needed=$("$READELF" -d "$library")
case "$needed" in
    *libgnutls*) ;;
    *) cross_port_fail "the gnutls module does not link libgnutls" ;;
esac

# Installing the module in the right place is not the same as gio loading it:
# a module that fails to register leaves the extension point empty and gio says
# nothing. Ask gio, with the same loader trick the meson cross file uses to run
# target binaries here. This is the offline half of tools/gio-tls-test.c -- a
# real handshake needs a network and belongs on the guest.
export PKG_CONFIG_LIBDIR="$GRAPHICS_SYSROOT/usr/lib/pkgconfig:$GRAPHICS_SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$GRAPHICS_SYSROOT"

# shellcheck disable=SC2046
"$CROSS_CC" -O2 -Wall -Wextra -o "$BUILD/gio-tls-check" "$ROOT/tools/gio-tls-test.c" \
    $(pkg-config --cflags gio-2.0) \
    -L"$GRAPHICS_SYSROOT/usr/lib" -Wl,-rpath-link,"$GRAPHICS_SYSROOT/usr/lib" \
    $(pkg-config --libs gio-2.0)

GIO_MODULE_DIR="$ROOT_DIR/$MODULE_DIR" \
    "$CROSS_LOADER" --library-path "$CROSS_SYSROOT/lib:$GRAPHICS_SYSROOT/usr/lib" \
    "$BUILD/gio-tls-check" || cross_port_fail \
    "gio did not accept the module as a TLS backend"

# The same check ships, so the question can be asked on the guest too -- where
# it can also be given a URL and do a real handshake.
install -Dm755 "$BUILD/gio-tls-check" "$ROOT_DIR/usr/bin/gio-tls-check"

cross_port_finalize_root "$ROOT_DIR"
# glib is in the list because the module links gio; the two roots after it are
# what glib itself closes over (zlib from the shared image codecs, libc).
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/gnutls-root" "$OUT/nettle-root" \
    "$OUT/gmp-root" "$OUT/libtasn1-root" "$OUT/glib-root" "$OUT/libffi-root" \
    "$OUT/image-codecs-shared-root" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'glib-networking %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
