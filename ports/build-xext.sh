#!/usr/bin/env bash
set -euo pipefail

# Build the X extension client libraries for Tunix, in dependency order, in one
# script (the build-libxcb.sh pattern). These are what X clients -- xfwm4, the
# X11 GTK3 backend, the Xfce panel -- link for RENDER, SHAPE, FIXES, DAMAGE,
# COMPOSITE, RANDR, XInput, XTEST, cursors and the rest.
#
# The set is split across build systems (recent X libs are migrating to meson):
#   autotools: libXext, libXrender, libXcursor, libXi, libXtst
#   meson:     libXfixes, libXdamage, libXcomposite, libXrandr, libXres,
#              libXinerama, libXkbfile
# so this drives both -- the cross-autotools path (cross_port_autotools_setup)
# and the meson cross file -- picking per library. After each install the staged
# .la files are dropped so the next lib links through .pc, not host /usr/lib.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for the clients above
#   $OUT/xext-root/usr/lib                    the shared libraries, for the image

PORT_NAME=xext
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

BUILD="$OUT/xext-build"
ROOT_DIR="$OUT/xext-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

cross_port_require_toolchain
cross_port_require_tools meson ninja autoreconf gcc pkg-config "$READELF"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/x11.pc" ]] || cross_port_fail \
    "libX11 is not in the sysroot; build it first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_autotools_setup
export ACLOCAL_PATH="$GRAPHICS_SYSROOT/usr/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"

strip_la() { find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete; }

build_auto() {
    local sub="$1"; shift
    local d="$BUILD/$sub"
    tar -C "$ROOT/ports/src/$sub" --exclude=.git -cf - . | { mkdir -p "$d"; tar -C "$d" -xf -; }
    ( cd "$d" && NOCONFIGURE=1 autoreconf -fi >/dev/null )
    ( cd "$d" && ./configure --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
        --prefix=/usr --disable-static --enable-shared "$@" )
    make -C "$d" -j "$JOBS"
    make -C "$d" DESTDIR="$GRAPHICS_SYSROOT" install
    make -C "$d" DESTDIR="$ROOT_DIR" install
    strip_la
}

build_meson() {
    local sub="$1"; shift
    # meson resolves the cross deps through the cross file; run with the autotools
    # pkg-config/flag env cleared so it does not fight meson's per-machine setup.
    ( unset PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR CFLAGS CPPFLAGS CXXFLAGS LDFLAGS
      meson setup "$BUILD/$sub-obj" "$ROOT/ports/src/$sub" --cross-file "$CROSS_FILE" \
          --prefix=/usr --libdir=lib --buildtype=release --default-library=shared "$@"
      meson compile -C "$BUILD/$sub-obj" -j "$JOBS"
      DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/$sub-obj" --no-rebuild
      DESTDIR="$ROOT_DIR" meson install -C "$BUILD/$sub-obj" --no-rebuild )
    strip_la
}

# Dependency order: libXext/Xrender first, then Xfixes and everything on it.
build_auto  libXext --disable-specs
build_auto  libXrender
build_meson libXfixes
build_meson libXdamage
build_meson libXcomposite
build_auto  libXcursor
build_auto  libXi --disable-specs
build_meson libXrandr
build_auto  libXtst
build_meson libXres
build_meson libXinerama
build_meson libXkbfile

for soname in libXext.so.6 libXrender.so.1 libXfixes.so.3 libXdamage.so.1 \
              libXcomposite.so.1 libXcursor.so.1 libXi.so.6 libXrandr.so.2 \
              libXtst.so.6 libXRes.so.1 libXinerama.so.1 libxkbfile.so.1; do
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$soname*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$soname was not installed"
    cross_port_check_library "$lib" "$soname"
done

# Image keeps the shared libraries only.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/libX11-root" "$OUT/xcb-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'X extension libraries (Xext, Xrender, Xfixes, Xrandr, Xi, Xcursor, ...) staged at %s (%s)\n' \
    "$ROOT_DIR" "$size"
