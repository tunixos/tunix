#!/usr/bin/env bash
set -euo pipefail

# Build LightDM for Tunix -- the display manager.
#
# What it adds over /bin/console-login plus tunix-session: the machine boots
# straight to a graphical login, and the X server, the session and the user's
# credentials are managed by one process that outlives any of them. The greeter
# is a separate program talking to the daemon over a private socket, which is
# why liblightdm-gobject is built too.
#
# Three things had to exist first:
#   Linux-PAM        LightDM has no non-PAM authentication path at all.
#   The VT ioctls    it asks the kernel for a free terminal before starting X.
#   D-Bus            the seat and session objects are published on the system bus.
#
# Feature choices: the Qt libraries, gobject-introspection, Vala and the test
# suite are all off; libxklavier is patched out (see the patch for why). XDMCP
# is left on because libXdmcp is already in the sysroot and configure requires
# it regardless.

PORT_NAME=lightdm
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/lightdm"
PATCH_DIR="$ROOT/ports/src/patches/lightdm"
BUILD="$OUT/lightdm-build"
BUILD_SRC="$BUILD/source"
BUILD_OBJ="$BUILD/obj"
ROOT_DIR="$OUT/lightdm-root"

EXPECTED_VERSION=1.32.0
version=$(sed -n 's/^AC_INIT(lightdm, \([0-9.]*\)).*/\1/p' "$SOURCE/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected lightdm $EXPECTED_VERSION, found ${version:-unknown}"

cross_port_require_toolchain
cross_port_require_tools autoconf automake autoheader aclocal libtoolize \
    intltoolize gtkdocize pkg-config "$READELF"
for module in glib-2.0 gio-2.0 gio-unix-2.0 gobject-2.0 xcb xdmcp x11; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" || \
       -f "$GRAPHICS_SYSROOT/usr/share/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done
[[ -f "$GRAPHICS_SYSROOT/usr/include/security/pam_appl.h" ]] || cross_port_fail \
    "PAM is not in the graphics sysroot; run ports/build-linux-pam.sh first"

# Patched, so build from a copy -- ports/src is never modified.
rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD_SRC" "$BUILD_OBJ" "$ROOT_DIR"
cp -a "$SOURCE/." "$BUILD_SRC/"
for patch in "$PATCH_DIR"/*.patch; do
    [[ -e "$patch" ]] || continue
    patch -d "$BUILD_SRC" -p1 --forward < "$patch" || \
        cross_port_fail "failed to apply $(basename "$patch")"
done

# Not ./autogen.sh: it insists on yelp-build for the user manual and exits
# before configure if it is absent. The manual is never shipped, so the same
# tools are run directly instead. gtkdocize still has to run -- doc/Makefile.am
# includes the gtk-doc.make it drops in, whether or not the docs are built.
(
    cd "$BUILD_SRC"
    libtoolize --force --copy
    intltoolize --force --copy
    gtkdocize --copy
    aclocal -I m4
    autoconf
    autoheader
    automake --add-missing --copy --foreign
) || cross_port_fail "bootstrapping the build system failed"

cross_port_autotools_setup

# LightDM writes its logs, the greeter's home and the X authority files below
# these, all of which are on tmpfs; --localstatedir keeps them out of /usr.
cross_port_configure "$BUILD_SRC" "$BUILD_OBJ" \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --libdir=/usr/lib \
    --sbindir=/usr/sbin \
    --disable-tests \
    --disable-introspection \
    --disable-vala \
    --disable-gtk-doc \
    --disable-liblightdm-qt5 \
    --disable-libaudit \
    --with-user-session=xfce \
    --with-greeter-session=lightdm-gtk-greeter \
    --with-greeter-user=lightdm

make -C "$BUILD_OBJ" -j"$JOBS"
# The greeter links liblightdm-gobject, so its headers and .pc go to the
# sysroot as well as the image root.
make -C "$BUILD_OBJ" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
find "$GRAPHICS_SYSROOT/usr/lib" -maxdepth 1 -name 'liblightdm*.la' -delete
make -C "$BUILD_OBJ" install DESTDIR="$ROOT_DIR"

[[ -x "$ROOT_DIR/usr/sbin/lightdm" ]] || cross_port_fail "lightdm was not installed"
[[ -f "$ROOT_DIR/usr/lib/liblightdm-gobject-1.so.0.0.0" ]] || \
    cross_port_fail "liblightdm-gobject was not installed"

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/help"
# Configuration for things Tunix does not have: AppArmor, Upstart, polkit and
# accounts-service. The guest session goes with them -- it wants all four.
rm -rf "$ROOT_DIR/etc/apparmor.d" "$ROOT_DIR/etc/init" \
       "$ROOT_DIR/usr/share/polkit-1" "$ROOT_DIR/usr/share/accountsservice" \
       "$ROOT_DIR/usr/libexec/lightdm-guest-session"
# The PAM policy and lightdm.conf belong to the image, not to the port: the
# initrd copy happens first, so anything left here would overwrite them.
rm -rf "$ROOT_DIR/etc/pam.d" "$ROOT_DIR/etc/lightdm/lightdm.conf"
find "$ROOT_DIR" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 2 -name '*.a' -delete 2>/dev/null || true

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/libX11-root" \
    "$OUT/xcb-root" "$OUT/libffi-root" "$OUT/linux-pam-root" \
    "$OUT/libgcrypt-root" "$OUT/image-codecs-shared-root" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'lightdm staged at %s (%s)\n' "$ROOT_DIR" "$size"
