#!/usr/bin/env bash
set -euo pipefail

# Build the Xorg X server for Tunix (meson) -- the DDX that turns the whole X
# library stack below it into a running display server. Two servers are built:
#   Xvfb   a virtual-framebuffer X server, all in RAM: no DRM, no VT, no PCI.
#          The de-risking stepping stone -- if Xvfb runs a client, the server
#          core + every X lib + the font stack are proven, before the hard
#          modesetting/VT work.
#   Xorg   the real server with the in-tree modesetting DDX, which drives KMS
#          through libdrm on Tunix's /dev/dri/card0. glamor is off, so it uses a
#          software shadow framebuffer -- exactly what a GPU-less DRM device wants.
#
# Deliberately off: glamor + DRI (no GL acceleration), pciaccess (Tunix's DRM is
# a platform/simpledrm device found via udev, not a PCI GPU), systemd-logind,
# secure-rpc, selinux, dtrace, libunwind. SHA1 comes from libgcrypt (already in
# the sysroot from the webkit port) since musl's libc has no SHA1Init.
#
# NOT solved here (the gate, task #6): Xorg's xf86OpenConsole wants /dev/tty0 +
# VT ioctls Tunix has no VT for. That is a runtime/patch problem, tackled once
# the server builds; the build itself is VT-agnostic.
#
# Output:
#   $OUT/xserver-root/usr/bin/{Xorg,Xvfb}   the servers
#   $OUT/xserver-root/usr/lib/xorg/...       the modules (modesetting DDX, ...)

PORT_NAME=xserver
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xserver"
BUILD="$OUT/xserver-build"
ROOT_DIR="$OUT/xserver-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE; run git submodule update --init"
cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config "$READELF"
for pc in pixman-1 xfont2 libdrm libudev xproto xtrans libgcrypt; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" || \
       -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc is not in the sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

# libxcvt: the CVT mode-timing library xserver 21.1+ links unconditionally. Tiny
# meson lib; build it first into the sysroot (and stage its .so with the server).
meson setup "$BUILD/libxcvt" "$ROOT/ports/src/libxcvt" --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared
meson compile -C "$BUILD/libxcvt" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/libxcvt" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/libxcvt" --no-rebuild
find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

# libpciaccess: the Xorg DDX's xf86platformBus.c includes pciaccess.h
# unconditionally, so even a GPU-less build needs the header + lib. At runtime it
# just finds no PCI GPU and the modesetting driver binds the platform DRM device.
meson setup "$BUILD/libpciaccess" "$ROOT/ports/src/libpciaccess" --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared -Dzlib=disabled
meson compile -C "$BUILD/libpciaccess" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD/libpciaccess" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/libpciaccess" --no-rebuild
find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

meson setup "$BUILD/obj" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release \
    -Dxorg=true \
    -Dxvfb=true \
    -Dxnest=false -Dxephyr=false -Dxwin=false \
    -Dglamor=false \
    -Dglx=false \
    -Ddri1=false -Ddri2=false -Ddri3=false \
    -Dpciaccess=true \
    -Dudev=true -Dudev_kms=true \
    -Dsystemd_logind=false \
    -Dsecure-rpc=false \
    -Dxselinux=false \
    -Ddtrace=false \
    -Dlibunwind=false \
    -Dsha1=libgcrypt \
    -Dxkb_dir=/usr/share/X11/xkb \
    -Dxkb_bin_dir=/usr/bin \
    -Ddocs=false -Ddevel-docs=false

if [[ "${XSERVER_CONFIGURE_ONLY:-0}" == "1" ]]; then
    printf 'xserver configure OK (%s)\n' "$BUILD/obj"
    exit 0
fi

meson compile -C "$BUILD/obj" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/obj" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/Xvfb" ]] || cross_port_fail "Xvfb was not produced"
[[ -x "$ROOT_DIR/usr/bin/Xorg" ]] || cross_port_fail "Xorg was not produced"

printf 'xserver 21.1.24 (Xorg + Xvfb, modesetting DDX, software shadow fb) staged at %s\n' \
    "$ROOT_DIR"
