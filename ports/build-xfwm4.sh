#!/usr/bin/env bash
set -euo pipefail

# Build xfwm4 for Tunix -- the Xfce window manager, and the first real Xfce X11
# component to run on the Tunix Xorg server. It is an ordinary X client: it talks
# to the display with Xlib + the extensions (randr/render/xinerama/xi2/xres/
# xsync) and manages windows over EWMH through libwnck. Its GTK3 settings dialogs
# need the x11 backend that GTK3 was just rebuilt with.
#
# Feature choices:
#   compositor/render/randr/xi2/xres/xsync  ON  -- all their X libs are ported;
#     the compositor is the Xrender one (no glamor/GLX on this server)
#   startup-notification                    ON  -- ported for libwnck
#   epoxy                                    OFF -- only used for GLX vblank, and
#     this Xorg has no GLX (-Dglx=false)
#   xpresent                                 OFF -- libXpresent is not ported
#
# Output: everything to $OUT/xfwm4-root (the binaries, themes, default settings,
# keyboard shortcuts and glade UI). It is a leaf app, so nothing goes to the SDK
# sysroot beyond what meson install writes there incidentally.

PORT_NAME=xfwm4
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xfwm4"
BUILD="$OUT/xfwm4-build"
ROOT_DIR="$OUT/xfwm4-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-genmarshal glib-mkenums "$READELF"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/gdk-x11-3.0.pc" ]] || cross_port_fail \
    "gdk-x11-3.0 is missing; rebuild GTK3 with x11_backend=true first"
for module in gtk+-3.0 libxfce4ui-2 libxfce4kbd-private-3 libxfce4util-1.0 \
              libxfconf-0 libwnck-3.0 x11 xinerama xrandr xrender; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release \
    -Dcompositor=enabled \
    -Drender=enabled \
    -Drandr=enabled \
    -Dxi2=enabled \
    -Dxres=enabled \
    -Dxsync=enabled \
    -Dstartup-notification=enabled \
    -Depoxy=disabled \
    -Dxpresent=disabled
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/xfwm4" ]] || cross_port_fail "xfwm4 was not installed"
machine=$("$READELF" -h "$ROOT_DIR/usr/bin/xfwm4" | sed -n 's/.*Machine:[[:space:]]*//p')
[[ "$machine" == *X86-64* ]] || cross_port_fail \
    "xfwm4 is not an x86-64 binary (got '$machine')"

# Leaf app: drop dev/locale/doc, keep bin + the themes, default settings, keyboard
# shortcuts and glade UI under share that xfwm4 loads at runtime.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/metainfo" "$ROOT_DIR/usr/share/appdata"
find "$ROOT_DIR/usr/lib" -maxdepth 2 -name '*.a' -delete 2>/dev/null || true

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root" "$OUT/xcb-util-root" \
    "$OUT/startup-notification-root" "$OUT/libwnck-root" "$OUT/libsm-root" \
    "$OUT/libxfce4util-root" "$OUT/xfconf-root" "$OUT/libxfce4ui-root" \
    "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xfwm4 (window manager + settings) staged at %s (%s)\n' "$ROOT_DIR" "$size"
