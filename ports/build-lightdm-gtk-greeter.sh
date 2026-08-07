#!/usr/bin/env bash
set -euo pipefail

# Build lightdm-gtk-greeter for Tunix -- the login screen itself.
#
# The greeter is an ordinary GTK3 X client. It has no privileges: it collects a
# username and a password and hands them to the LightDM daemon over the socket
# on LIGHTDM_TO_SERVER_FD, and the daemon is the only thing that ever sees
# /etc/shadow. That split is why the greeter can be a normal desktop program.
#
# Everything optional is off: the Ayatana/Unity indicators, at-spi and
# libxklavier are not ported, and the greeter is built to work without them --
# it falls back to the LightDM API for layouts, which on Tunix reports none.

PORT_NAME=lightdm-gtk-greeter
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/lightdm-gtk-greeter"
BUILD="$OUT/lightdm-gtk-greeter-build"
BUILD_SRC="$BUILD/source"
# In-tree, deliberately. src/Makefile.am generates three headers with
# xdt-csource and the sources include them as "src/lightdm-gtk-greeter-ui.h",
# but the compile line carries -I$(top_srcdir) and not -I$(top_builddir) -- so
# a separate object directory never finds them. The source is a copy anyway.
BUILD_OBJ="$BUILD_SRC"
ROOT_DIR="$OUT/lightdm-gtk-greeter-root"

EXPECTED_VERSION=2.0.9
version=$(sed -n 's/^AC_INIT(\[lightdm-gtk-greeter\],\[\([0-9.]*\)\].*/\1/p' "$SOURCE/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected lightdm-gtk-greeter $EXPECTED_VERSION, found ${version:-unknown}"

cross_port_require_toolchain
cross_port_require_tools autoconf automake aclocal libtoolize intltoolize \
    xdt-csource pkg-config "$READELF"
for module in gtk+-3.0 gmodule-export-2.0 liblightdm-gobject-1 x11; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD_SRC" "$BUILD_OBJ" "$ROOT_DIR"
cp -a "$SOURCE/." "$BUILD_SRC/"

# NOCONFIGURE: autogen.sh would otherwise run configure for the build host.
( cd "$BUILD_SRC" && NOCONFIGURE=1 ./autogen.sh ) || \
    cross_port_fail "bootstrapping the build system failed"

cross_port_autotools_setup

# --enable-maintainer-mode is not optional here: the glade file and the two
# stylesheets are turned into C headers by xdt-csource, and those rules live
# inside the MAINTAINER_MODE conditional. A release tarball ships the generated
# headers; a git checkout does not.
cross_port_configure "$BUILD_SRC" "$BUILD_OBJ" \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --libdir=/usr/lib \
    --sbindir=/usr/sbin \
    --disable-at-spi-command \
    --disable-indicator-services-command \
    --disable-libindicator \
    --disable-libido \
    --enable-maintainer-mode

make -C "$BUILD_OBJ" -j"$JOBS"
make -C "$BUILD_OBJ" install DESTDIR="$ROOT_DIR"

[[ -x "$ROOT_DIR/usr/sbin/lightdm-gtk-greeter" ]] || \
    cross_port_fail "lightdm-gtk-greeter was not installed"
# The .desktop file is how the daemon finds the greeter: it looks up
# greeter-session in /usr/share/xgreeters.
[[ -f "$ROOT_DIR/usr/share/xgreeters/lightdm-gtk-greeter.desktop" ]] || \
    cross_port_fail "the greeter desktop entry was not installed"

rm -rf "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/locale"
find "$ROOT_DIR" -name '*.la' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/lightdm-root" "$OUT/gtk3-root" \
    "$OUT/glib-root" "$OUT/pango-root" "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" \
    "$OUT/pixman-root" "$OUT/libffi-root" "$OUT/libX11-root" "$OUT/xcb-root" \
    "$OUT/xext-root" "$OUT/fontstack-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/libxml2-root" "$OUT/mesa-root" "$OUT/libdrm-root" \
    "$OUT/llvm-root" "$OUT/libdisplay-info-root" "$OUT/icu-root" \
    "$OUT/image-codecs-shared-root" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'lightdm-gtk-greeter staged at %s (%s)\n' "$ROOT_DIR" "$size"
