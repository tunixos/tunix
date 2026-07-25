#!/usr/bin/env bash
set -euo pipefail

# Build libICE + libSM for Tunix -- the X11 Inter-Client Exchange and Session
# Management libraries. They enter with the Xfce X11 desktop: libxfce4ui's
# session-management support (XfceSMClient) links them, and xfwm4 / xfce4-session
# use that to save and restore a session. libSM sits on top of libICE, so the
# order is forced.
#
# Two cross autotools libs (the build-xcb-util.sh pattern) on xproto + xtrans.
# libuuid is declined (--without-libuuid): it only supplies globally-unique client
# IDs, and pulling in util-linux's libuuid is not worth it here.
#
# Payload: libICE.so.6 + libSM.so.6 -> sysroot + image; headers/.pc -> sysroot.

PORT_NAME=libSM
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

BUILD="$OUT/libsm-build"
ROOT_DIR="$OUT/libsm-root"

cross_port_require_toolchain
cross_port_require_tools pkg-config autoreconf gcc "$READELF"
for sub in libICE libSM; do
    [[ -f "$ROOT/ports/src/$sub/configure.ac" ]] || cross_port_fail \
        "missing ports/src/$sub; run git submodule update --init"
done
[[ -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/xproto.pc" ]] || cross_port_fail \
    "xorgproto is not in the sysroot; build it first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_autotools_setup

# An autotools X lib: autoreconf on a copy (ports/src stays clean), cross-configure,
# install to the sysroot and the image root.
build_autotools() {
    local sub="$1"; shift
    local d="$BUILD/$sub"
    tar -C "$ROOT/ports/src/$sub" --exclude=.git -cf - . | { mkdir -p "$d"; tar -C "$d" -xf -; }
    ( cd "$d" && NOCONFIGURE=1 autoreconf -fi >/dev/null 2>&1 )
    ( cd "$d" && ./configure --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
        --prefix=/usr --disable-static --enable-shared "$@" )
    make -C "$d" -j "$JOBS"
    make -C "$d" DESTDIR="$GRAPHICS_SYSROOT" install
    make -C "$d" DESTDIR="$ROOT_DIR" install
}

build_autotools libICE --without-docs
build_autotools libSM --without-docs --without-libuuid

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

for pc in ice sm; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc.pc was not installed into the sysroot"
done

for spec in "libICE.so.6:libICE.so.6" "libSM.so.6:libSM.so.6"; do
    name=${spec%%:*}; soname=${spec##*:}
    lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$lib" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$lib" "$soname"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libICE is self-contained (musl only); libSM links libICE, both here.
cross_port_check_runtime_closure "$ROOT_DIR"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libICE 1.1.2 + libSM 1.2.6 staged at %s (%s)\n' "$ROOT_DIR" "$size"
