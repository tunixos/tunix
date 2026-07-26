#!/usr/bin/env bash
set -euo pipefail

# Build xfce4-session for Tunix -- the Xfce session manager. It starts the rest
# of the session (settings daemon, window manager, panel, desktop), tracks them
# over X11 session management (libSM/libICE) and provides logout/shutdown. The
# `startxfce4` launcher and `xfce4-session` daemon come from here.
#
# Feature choices: x11 on, wayland off; polkit (used only for the shutdown/
# suspend helper) and gtk-layer-shell off -- neither is ported and logout still
# works, it just cannot power off the machine itself.

PORT_NAME=xfce4-session
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/xfce4-session"
BUILD="$OUT/xfce4-session-build"
ROOT_DIR="$OUT/xfce4-session-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"

[[ -f "$SOURCE/meson.build" ]] || cross_port_fail \
    "missing $SOURCE/meson.build; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools meson ninja pkg-config xdt-gen-visibility \
    glib-genmarshal glib-mkenums "$READELF"
for module in gtk+-3.0 gdk-x11-3.0 libxfce4ui-2 libxfce4util-1.0 libxfconf-0 \
              libwnck-3.0 libxfce4windowing-0 sm ice; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_export_pkg_config

# xfce4-session runs gdk-pixbuf-csource at build time (to embed the chooser icon),
# but resolves it from gdk-pixbuf-2.0.pc's gdk_pixbuf_csource variable, which
# points at the *target* binary staged in the sysroot -- a musl binary that will
# not run on the build host. Point that path at the host tool for the build.
ln -sf /usr/bin/gdk-pixbuf-csource "$GRAPHICS_SYSROOT/usr/bin/gdk-pixbuf-csource"

meson setup "$BUILD" "$SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release \
    -Dx11=enabled \
    -Dwayland=disabled \
    -Dpolkit=disabled \
    -Dgtk-layer-shell=disabled
meson compile -C "$BUILD" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD" --no-rebuild

[[ -x "$ROOT_DIR/usr/bin/xfce4-session" ]] || cross_port_fail "xfce4-session was not installed"
[[ -x "$ROOT_DIR/usr/bin/startxfce4" ]] || cross_port_fail "startxfce4 was not installed"

# Keep bin + libexec (the helpers) + the session share data (the default
# xinitrc, the .desktop autostarts); drop dev/locale/doc.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/gtk-doc" "$ROOT_DIR/usr/share/locale" \
       "$ROOT_DIR/usr/share/man"
find "$ROOT_DIR/usr/lib" -maxdepth 2 -name '*.a' -delete 2>/dev/null || true

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/glib-root" "$OUT/pango-root" \
    "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/gtk3-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" "$OUT/libX11-root" "$OUT/xext-root" \
    "$OUT/xcb-root" "$OUT/xcb-util-root" "$OUT/startup-notification-root" \
    "$OUT/libwnck-root" "$OUT/libsm-root" "$OUT/libxfce4util-root" "$OUT/xfconf-root" \
    "$OUT/libxfce4ui-root" "$OUT/libxfce4windowing-root" "$OUT/libdisplay-info-root" \
    "$OUT/llvm-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xfce4-session staged at %s (%s)\n' "$ROOT_DIR" "$size"
