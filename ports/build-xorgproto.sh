#!/usr/bin/env bash
set -euo pipefail

# Build xorgproto for Tunix -- the X11 protocol headers, the bedrock the whole
# X library stack (libX11, libxcb consumers, Xext, the server) is built against.
#
# This is the first rung of the Xorg foundation. Xfce is at heart an X11 desktop
# (xfwm4, xfce4-panel, xfdesktop have no Wayland form), so a real Xfce needs an X
# server; Tunix already has the hard prerequisites -- the DRM/KMS driver, evdev
# input and mesa -- so the X stack + Xorg is reachable.
#
# xorgproto ships nothing to the image: it is headers and pkg-config data only,
# consumed at build time, like wayland-protocols. -Dlegacy=false drops the
# obsolete protocol .pc files (XF86Misc, Xxf86dga, ...) nothing modern wants.
#
# Output:
#   $OUT/graphics-sysroot/usr/include/X11        the protocol headers
#   $OUT/graphics-sysroot/usr/share/pkgconfig    xproto.pc, xextproto.pc, ...

PORT_NAME=xorgproto
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xorgproto"
BUILD="$OUT/xorgproto-build"

EXPECTED_VERSION=2025.1

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"
cross_port_require_tools meson ninja

version=$(sed -n "s/.*version *: *'\([0-9.]*\)'.*/\1/p" "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected xorgproto $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD"
mkdir -p "$BUILD"

# No compilation happens (headers + .pc only), so a native meson configure is
# enough; the install just copies data into the graphics sysroot.
meson setup "$BUILD" "$SOURCE" \
    --prefix=/usr --datadir=share --buildtype=release \
    -Dlegacy=false
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild

[[ -f "$GRAPHICS_SYSROOT/usr/include/X11/X.h" ]] || \
    cross_port_fail "the core X11 headers were not installed"
[[ -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/xproto.pc" ]] || \
    cross_port_fail "xproto.pc was not installed"

printf 'xorgproto %s (headers + pkg-config, no image payload) staged into the sysroot\n' \
    "$version"
