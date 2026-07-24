#!/usr/bin/env bash
set -euo pipefail

# Build xfconf for Tunix -- the Xfce configuration store. libxfce4ui and Thunar
# both link its client library (libxfconf), so it comes before them in the chain.
#
# The reason xfconf is reachable at all without a D-Bus port: since 4.16 it talks
# GDBus (from GIO) rather than libdbus/dbus-glib, so the client library and the
# xfconfd daemon build against glib alone. With no session bus running the
# clients simply fail to reach xfconfd and the Xfce apps fall back to their
# built-in defaults -- settings do not persist, but nothing aborts.
#
# 4.21.x, not the 4.20 stable line: xfconf only grew a working meson.build in the
# 4.21 development series (4.20.0 is autotools-only), and the whole cross-port
# infrastructure here is meson/cmake. The API is the stable xfconf-0, so the
# 4.21.x libxfconf satisfies every consumer's ">= 4.17" check.
#
# Disabled: introspection (no girepository host stack), vala, gtk-doc, and the
# GSettings backend module (a gio module nothing on the image loads).
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib,share}  headers + .pc for libxfce4ui
#                                                  and Thunar
#   $OUT/xfconf-root/usr/{lib,bin}                 libxfconf + xfconfd +
#                                                  xfconf-query, for the image

PORT_NAME=xfconf
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xfconf"
BUILD="$OUT/xfconf-build"
ROOT_DIR="$OUT/xfconf-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

EXPECTED_VERSION=4.21.2

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init --recursive"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-mkenums glib-genmarshal gdbus-codegen "$READELF"

version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected xfconf $EXPECTED_VERSION, found ${version:-unknown}"

for module in glib-2.0 gio-2.0 gio-unix-2.0 gmodule-2.0 gthread-2.0 libxfce4util-1.0; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=false \
    -Dvala=disabled \
    -Dgtk-doc=false \
    -Dgsettings-backend=false \
    -Dtests=false
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$BUILD" --no-rebuild
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libxfconf-0.pc" ]] || \
    cross_port_fail "libxfconf-0.pc was not installed into the graphics sysroot"

library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libxfconf-0.so.3*' -print -quit)
[[ -n "$library" ]] || cross_port_fail "libxfconf-0.so.3 was not installed"
cross_port_check_library "$library" "libxfconf-0.so.3"
[[ -x "$ROOT_DIR/usr/bin/xfconf-query" ]] || cross_port_fail "xfconf-query was not produced"

# The image keeps the library, the daemon, the query tool and the D-Bus service
# descriptors (so a session bus, if ever run, can activate xfconfd). Headers,
# .pc, developer data and locale catalogues are dropped.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/man" \
       "$ROOT_DIR/usr/share/doc" "$ROOT_DIR/usr/share/gtk-doc" \
       "$ROOT_DIR/usr/share/aclocal" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/bash-completion" "$ROOT_DIR/usr/share/vala" \
       "$ROOT_DIR/usr/lib/systemd"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/xfconf-query" 2>/dev/null || true
[[ -x "$ROOT_DIR/usr/sbin/xfconfd" ]] && "$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/sbin/xfconfd" 2>/dev/null || true
find "$ROOT_DIR/usr/libexec" -type f -exec "$CROSS_STRIP" --strip-all {} + 2>/dev/null || true

cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" \
    "$OUT/libxfce4util-root" "$OUT/cairo-root" "$OUT/libffi-root" "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xfconf %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
