#!/usr/bin/env bash
set -euo pipefail

# Build libX11 for Tunix -- the core Xlib, the library every X client links. It
# sits on the xcb base stack (xtrans + libxcb) via the cross-autotools path
# cross-port.sh grew for the X libraries; autoreconf runs on a copy so ports/src
# stays clean.
#
# Unlike libxcb, libX11 ships runtime *data* the image needs, not just a .so:
# /usr/share/X11/locale (the locale + compose tables Xlib loads at startup) and
# /usr/lib/X11 (XErrorDB, the Compose/Keysym databases). An X app aborts or
# mis-renders text without them, so usr/share/X11 and usr/lib/X11 are kept.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for the X libs above
#   $OUT/libX11-root/usr/lib                  libX11.so.6, libX11-xcb.so.1
#   $OUT/libX11-root/usr/{share,lib}/X11      the locale + error databases

PORT_NAME=libX11
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/libX11"
BUILD="$OUT/libX11-build"
ROOT_DIR="$OUT/libX11-root"

EXPECTED_VERSION=1.8.10

[[ -f "$SOURCE/configure.ac" ]] || cross_port_fail \
    "missing $SOURCE; run git submodule update --init"
cross_port_require_toolchain
cross_port_require_tools autoreconf gcc pkg-config perl "$READELF"

version=$(sed -n 's/^AC_INIT(\[libX11\], *\[\([0-9.]*\)\].*/\1/p' "$SOURCE/configure.ac" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected libX11 $EXPECTED_VERSION, found ${version:-unknown}"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/xcb.pc" ]] || cross_port_fail \
    "the xcb base stack is not in the sysroot; build libxcb first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_autotools_setup
# autoreconf must find xtrans.m4 (staged in the sysroot's aclocal too).
export ACLOCAL_PATH="$GRAPHICS_SYSROOT/usr/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"

tar -C "$SOURCE" --exclude=.git -cf - . | { mkdir -p "$BUILD/src"; tar -C "$BUILD/src" -xf -; }
( cd "$BUILD/src" && NOCONFIGURE=1 autoreconf -fi >/dev/null )
# --enable-malloc0returnsnull: skip the malloc(0) run-test autoconf can't do when
# cross-compiling (musl returns a unique pointer, so the "returns null" workaround
# is off). The doc toolchain is disabled: no xmlto/fop/xsltproc needed.
( cd "$BUILD/src" && ./configure \
    --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
    --prefix=/usr --disable-static --enable-shared \
    --enable-malloc0returnsnull \
    --disable-specs --without-xmlto --without-fop --without-xsltproc )
make -C "$BUILD/src" -j "$JOBS"
make -C "$BUILD/src" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD/src" DESTDIR="$ROOT_DIR" install

# Drop the staged .la files so the Xext libs above link libX11 through its .pc
# rather than following /usr/lib absolute paths to the host (the libxcb fix).
find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/x11.pc" ]] || \
    cross_port_fail "x11.pc was not installed into the sysroot"
for spec in "libX11.so.6:libX11.so.6" "libX11-xcb.so.1:libX11-xcb.so.1"; do
    name=${spec%%:*}; soname=${spec##*:}
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$lib" "$soname"
done
[[ -d "$ROOT_DIR/usr/share/X11/locale" ]] || \
    cross_port_fail "the X11 locale data was not installed"

# Keep the shared libraries and the X11 runtime data; drop dev files.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/aclocal"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libX11 links libxcb (xcb-root) + libc (musl runtime); the X11 data is inert.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/xcb-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libX11 %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
