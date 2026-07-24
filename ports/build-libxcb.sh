#!/usr/bin/env bash
set -euo pipefail

# Build the base of the X client stack for Tunix, in one strictly-ordered script
# (the build-cairo.sh pattern): xtrans, libXau, libXdmcp, xcb-proto, libxcb.
# libxcb links libXau + libXdmcp and generates its protocol code from xcb-proto's
# XML with the xcbgen python module, so the order is forced.
#
# These are the first cross *autotools* ports against the graphics sysroot (the
# X libraries are autotools, except libXau which is meson). cross-port.sh grew
# cross_port_autotools_setup / cross_port_configure for exactly this: the musl
# cross toolchain + sysroot include/lib flags + a sysroot-aware pkg-config, the
# autotools analogue of the meson cross file. autoreconf runs on a copy so
# ports/src stays clean (the weston copy-then-build pattern).
#
# Payload split:
#   xtrans, xcb-proto  headers / python data only -> sysroot, nothing to image
#   libXau, libXdmcp   .so -> sysroot + image
#   libxcb             libxcb.so + the per-extension libxcb-*.so -> sysroot + image

PORT_NAME=libxcb
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

BUILD="$OUT/xcb-build"
ROOT_DIR="$OUT/xcb-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config autoreconf gcc python3 "$READELF"
[[ -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/xproto.pc" ]] || cross_port_fail \
    "xorgproto is not in the sysroot; build it first"

for sub in libxtrans libXau libXdmcp xcbproto libxcb; do
    [[ -e "$ROOT/ports/src/$sub/configure.ac" || -e "$ROOT/ports/src/$sub/meson.build" ]] || \
        cross_port_fail "missing ports/src/$sub; run git submodule update --init"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"

# --- autotools cross environment (CC/CFLAGS/pkg-config sysroot/ld-musl shim) ---
cross_port_autotools_setup
# libxcb's generator imports xcbgen, installed by xcb-proto into the sysroot's
# python site-packages; make it importable for the host python during the build.
site=$(python3 -c 'import sys;print("python%d.%d"%sys.version_info[:2])')
export PYTHONPATH="$GRAPHICS_SYSROOT/usr/lib/$site/site-packages${PYTHONPATH:+:$PYTHONPATH}"

# Copy a submodule out of ports/src (no .git) so autoreconf can write into it.
copy_src() {
    local sub="$1" dest="$BUILD/$1"
    tar -C "$ROOT/ports/src/$sub" --exclude=.git -cf - . | { mkdir -p "$dest"; tar -C "$dest" -xf -; }
    printf '%s' "$dest"
}

# An autotools lib: autoreconf on the copy, configure, make, install to the
# sysroot and (when it produces libraries) to the image root.
build_autotools() {
    local sub="$1" image="$2"; shift 2   # image=yes stages .so into ROOT_DIR
    local d; d=$(copy_src "$sub")
    ( cd "$d" && NOCONFIGURE=1 autoreconf -fi >/dev/null )
    ( cd "$d" && ./configure --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
        --prefix=/usr --disable-static --enable-shared "$@" )
    make -C "$d" -j "$JOBS"
    make -C "$d" DESTDIR="$GRAPHICS_SYSROOT" install
    if [[ "$image" == yes ]]; then
        make -C "$d" DESTDIR="$ROOT_DIR" install
    fi
}

# --- xtrans: transport headers + m4, no build artefacts, sysroot only ---
build_autotools libxtrans no

# --- libXau (meson): the auth cookie library ---
meson setup "$BUILD/libXau-obj" "$ROOT/ports/src/libXau" \
    --cross-file "$CROSS_FILE" --prefix=/usr --libdir=lib \
    --buildtype=release --default-library=shared
meson compile -C "$BUILD/libXau-obj" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/libXau-obj" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/libXau-obj" --no-rebuild

# --- libXdmcp: the display-manager auth library ---
build_autotools libXdmcp yes --without-docs

# --- xcb-proto: the XML protocol descriptions + xcbgen, build-time only ---
build_autotools xcbproto no

# --- libxcb: the X C binding + per-extension libraries ---
build_autotools libxcb yes --without-doxygen --disable-devel-docs

# libtool .la files staged in the sysroot record libdir=/usr/lib and absolute
# dependency_libs; a later cross libtool link (libX11, the Xext libs) follows
# them to the *host* /usr/lib and fails. Drop them so downstream links resolve
# through the .pc files instead (the webkit trap-4 fix, generalised to the X libs).
find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

# xtrans is arch-independent so its .pc lands in share/pkgconfig; the libraries'
# .pc files are in lib/pkgconfig.
[[ -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/xtrans.pc" ]] || cross_port_fail \
    "xtrans.pc was not installed into the sysroot"
for pc in xau xdmcp xcb; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc.pc was not installed into the sysroot"
done

for spec in "libXau.so.6:libXau.so.6" "libXdmcp.so.6:libXdmcp.so.6" "libxcb.so.1:libxcb.so.1"; do
    name=${spec%%:*}; soname=${spec##*:}
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$lib" "$soname"
done

# Image keeps the shared libraries only; headers, .pc, .la and dev symlinks go.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# Self-contained: libxcb links libXau/libXdmcp (both here); libc is the musl runtime.
cross_port_check_runtime_closure "$ROOT_DIR"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xcb base stack (xtrans, libXau, libXdmcp, xcb-proto, libxcb) staged at %s (%s)\n' \
    "$ROOT_DIR" "$size"
