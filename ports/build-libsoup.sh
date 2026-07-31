#!/usr/bin/env bash
set -euo pipefail

# Build libpsl and libsoup 2.74 for Tunix -- WebKit's HTTP stack.
#
# libsoup 2 rather than 3, deliberately: WebKitGTK 2.44's soup2 API
# (webkit2gtk-4.0) needs neither nghttp2 nor HTTP/2 plumbing, and the rest
# of the image has no other soup consumer to share with.
#
# libpsl carries the public suffix list compiled in (-Druntime=no): cookie
# domain checks work against the list frozen at build time, with no libicu
# or libidn2 runtime dependency. Non-ASCII domain lookups lose IDN
# conversion, which Tunix can live with.
#
# TLS is a known, accepted gap: https needs a glib-networking TLS backend
# (gnutls or openssl), neither of which is ported yet. http:// and file://
# work; -Dtls_check=false says we know.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for webkit
#   $OUT/libsoup-root/usr/lib                 libpsl, libsoup-2.4

PORT_NAME=libsoup
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

PSL_SOURCE="$ROOT/ports/src/libpsl"
SOUP_SOURCE="$ROOT/ports/src/libsoup"

BUILD="$OUT/libsoup-build"
ROOT_DIR="$OUT/libsoup-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_SOUP_VERSION=2.74.3

for source in "$PSL_SOURCE/meson.build" "$SOUP_SOURCE/meson.build"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done
[[ -f "$PSL_SOURCE/list/public_suffix_list.dat" ]] || cross_port_fail \
    "libpsl's suffix list is missing; run git -C ports/src/libpsl submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config python3 "$READELF"

soup_version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOUP_SOURCE/meson.build" | head -n1)
[[ "$soup_version" == "$EXPECTED_SOUP_VERSION" ]] || \
    cross_port_fail "expected libsoup $EXPECTED_SOUP_VERSION, found ${soup_version:-unknown}"

for module in glib-2.0 gio-2.0 sqlite3 libxml-2.0 libbrotlidec zlib; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

install_both() {
    DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$1" --no-rebuild
    DESTDIR="$ROOT_DIR" meson install -C "$1" --no-rebuild
}

# --- libpsl --------------------------------------------------------------
meson setup "$BUILD/libpsl" "$PSL_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Druntime=no \
    -Dtests=false -Ddocs=false
meson compile -C "$BUILD/libpsl" -j "$JOBS"
install_both "$BUILD/libpsl"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libpsl.pc" ]] || \
    cross_port_fail "libpsl.pc was not installed"

# --- libsoup -------------------------------------------------------------
meson setup "$BUILD/libsoup" "$SOUP_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dgssapi=disabled \
    -Dntlm=disabled \
    -Dbrotli=enabled \
    -Dgnome=false \
    -Dintrospection=disabled \
    -Dvapi=disabled \
    -Dsysprof=disabled \
    -Dtls_check=false \
    -Dtests=false \
    -Dinstalled_tests=false
meson compile -C "$BUILD/libsoup" -j "$JOBS"
install_both "$BUILD/libsoup"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libsoup-2.4.pc" ]] || \
    cross_port_fail "libsoup-2.4.pc was not installed"

for spec in "libpsl.so.5:libpsl.so.5" "libsoup-2.4.so.1:libsoup-2.4.so.1"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/bin" \
       "$ROOT_DIR/usr/share" "$ROOT_DIR/usr/libexec"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# mesa-root ships libstdc++ (woff2's libraries are C++), libdrm-root closes
# over mesa's own winsys.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/libxml2-root" \
    "$OUT/sqlite-root" "$OUT/woff2-root" "$OUT/cairo-root" "$OUT/libffi-root" \
    "$OUT/pixman-root" "$OUT/mesa-root" "$OUT/libdrm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libpsl + libsoup %s staged at %s (%s)\n' "$soup_version" "$ROOT_DIR" "$size"
