#!/usr/bin/env bash
set -euo pipefail

# Build D-Bus for Tunix -- libdbus-1 plus the dbus-daemon message bus and its
# tools (dbus-launch, dbus-uuidgen, dbus-send, dbus-monitor). This is the piece
# the Xfce *session* needs: xfconfd, xfwm4, xfce4-panel and friends all reach
# their config store and each other over a D-Bus *session bus*. GLib's GDBus
# (already ported) is only the client side; it still needs this daemon listening.
#
# Minimal build: expat (from the cairo chain) + pthreads, everything else off --
# no systemd/elogind, no selinux/apparmor/libaudit, no X11 autolaunch (the
# session bus is launched explicitly), no docs, no tests.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib}   libdbus-1 headers + .pc (for GDBus
#                                             consumers that link libdbus, rare)
#   $OUT/dbus-root/usr/...                     libdbus-1.so.3, dbus-daemon, the
#                                             tools, and the session/system config

PORT_NAME=dbus
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/dbus"
BUILD="$OUT/dbus-build"
ROOT_DIR="$OUT/dbus-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config "$READELF"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/expat.pc" ]] || cross_port_fail \
    "expat is not in the sysroot; build the cairo chain first"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --sysconfdir=/etc --localstatedir=/var \
    --buildtype=release --default-library=shared \
    -Dmessage_bus=true \
    -Dtools=true \
    -Dsystemd=disabled \
    -Delogind=disabled \
    -Dselinux=disabled \
    -Dapparmor=disabled \
    -Dlibaudit=disabled \
    -Dx11_autolaunch=disabled \
    -Ddoxygen_docs=disabled \
    -Dxml_docs=disabled \
    -Dducktype_docs=disabled \
    -Dqt_help=disabled \
    -Dmodular_tests=disabled \
    -Dinstalled_tests=false \
    -Dintrusive_tests=false \
    -Drelocation=disabled
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/dbus-1.pc" ]] || \
    cross_port_fail "dbus-1.pc was not installed into the sysroot"

lib=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libdbus-1.so.3*' -print -quit)
[[ -n "$lib" ]] || cross_port_fail "libdbus-1.so.3 was not installed"
cross_port_check_library "$lib" libdbus-1.so.3
# dbus-daemon lands in $libexecdir or $bindir depending on the build; find it.
daemon=$(find "$ROOT_DIR" -name 'dbus-daemon' -type f -print -quit)
[[ -n "$daemon" ]] || cross_port_fail "dbus-daemon was not installed"

# The image keeps the library, the daemon + tools and the bus configuration
# (session.conf / system.conf and the services dirs); drop dev files, docs, cmake.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/man"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
# libdbus links only expat (cairo-root ships libexpat) and the musl runtime; the
# X roots come along because cairo-root's own libcairo now needs libX11 (the
# xlib backend), which the closure walk would otherwise flag.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/cairo-root" "$OUT/pixman-root" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'dbus (libdbus-1 + dbus-daemon + tools) staged at %s (%s)\n' "$ROOT_DIR" "$size"
