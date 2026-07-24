#!/usr/bin/env bash
set -euo pipefail

# Build the Xorg server's font stack for Tunix: font-util, encodings, libfontenc,
# libXfont2. The X server loads fonts through libXfont2 (freetype-backed here),
# which needs libfontenc + the encodings tables; font-util supplies the m4 macros
# and mapping data the font ports build against.
#
# Mixed build systems again (the build-xext.sh dispatcher): font-util and
# libXfont2 are autotools, encodings and libfontenc are meson.
#
# Payload:
#   font-util          m4 + maps -> sysroot only (build-time)
#   encodings          the encoding tables -> sysroot + image (libfontenc reads them)
#   libfontenc         libfontenc.so -> sysroot + image
#   libXfont2          libXfont2.so -> sysroot + image (the server links it)

PORT_NAME=fontstack
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

BUILD="$OUT/fontstack-build"
ROOT_DIR="$OUT/fontstack-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

cross_port_require_toolchain
cross_port_require_tools meson ninja autoreconf gcc pkg-config "$READELF"
for pc in xproto freetype2 zlib; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" || \
       -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc is not in the sysroot; build the graphics stack first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_autotools_setup
export ACLOCAL_PATH="$GRAPHICS_SYSROOT/usr/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"

strip_la() { find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete; }

build_auto() {
    local sub="$1" image="$2"; shift 2
    local d="$BUILD/$sub"
    tar -C "$ROOT/ports/src/$sub" --exclude=.git -cf - . | { mkdir -p "$d"; tar -C "$d" -xf -; }
    ( cd "$d" && NOCONFIGURE=1 autoreconf -fi >/dev/null )
    ( cd "$d" && ./configure --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
        --prefix=/usr --disable-static --enable-shared "$@" )
    make -C "$d" -j "$JOBS"
    make -C "$d" DESTDIR="$GRAPHICS_SYSROOT" install
    [[ "$image" == yes ]] && make -C "$d" DESTDIR="$ROOT_DIR" install
    strip_la
}

build_meson() {
    local sub="$1" image="$2"; shift 2
    ( unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR CFLAGS CPPFLAGS CXXFLAGS LDFLAGS
      meson setup "$BUILD/$sub-obj" "$ROOT/ports/src/$sub" --cross-file "$CROSS_FILE" \
          --prefix=/usr --libdir=lib --buildtype=release --default-library=shared "$@"
      meson compile -C "$BUILD/$sub-obj" -j "$JOBS"
      DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/$sub-obj" --no-rebuild
      [[ "$image" == yes ]] && DESTDIR="$ROOT_DIR" meson install -C "$BUILD/$sub-obj" --no-rebuild )
    strip_la
}

build_auto  font-util  no
build_meson encodings  yes
build_meson libfontenc yes
build_auto  libXfont2  yes

for soname in libfontenc.so.1 libXfont2.so.2; do
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$soname*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$soname was not installed"
    cross_port_check_library "$lib" "$soname"
done

# Image keeps the two libraries and the encodings data; drop dev files.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libXfont2 links libfontenc (here), freetype + zlib (cairo-root). pixman-root is
# only here to satisfy cairo-root's own libcairo (which the closure walk visits),
# not anything the font stack uses.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/cairo-root" "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'X font stack (font-util, encodings, libfontenc, libXfont2) staged at %s (%s)\n' \
    "$ROOT_DIR" "$size"
