#!/usr/bin/env bash
set -euo pipefail

# Build WebKitGTK for Tunix -- the webkit2gtk-4.0 (GTK3 + libsoup2) API of
# WebKit 2.44, the last series that renders with cairo rather than skia.
# That matters here: cairo into wl_shm buffers is the exact path weston's
# renderer already composites for every GTK3 app on the image.
#
# What is deliberately off, and why:
#
#   JIT / WebAssembly       JSC runs on the CLoop interpreter. The JIT wants
#                           W^X remapping games the Tunix kernel has never
#                           been asked to play; correctness first.
#   system malloc           bmalloc's madvise/partition tricks are exactly
#                           the kind of edge a young kernel trips on.
#   video / audio           no gstreamer port.
#   WebGL / GPU process     mesa is softpipe; GL compositing would be slower
#                           than the software path, not faster.
#   sandbox                 no bubblewrap, no seccomp on Tunix.
#   spellcheck, gamepad,    each is a port (enchant, libmanette, flite,
#   speech, hyphenation,    libhyphen, lcms2, libsecret) nothing else needs.
#   color mgmt, secrets
#   introspection, docs     build-time machinery with no consumer.
#
# The tree is too big to compile over drvfs, so the source is rsynced to
# native ext4 first and patched there (never in ports/src); the build dir
# lives beside it. ~9p reads of a few thousand C++ TUs is the difference
# between an afternoon and a week.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc (webkit2gtk-4.0)
#   $OUT/webkitgtk-root/usr/lib               libwebkit2gtk, libjavascriptcoregtk
#   $OUT/webkitgtk-root/usr/libexec           WebProcess, NetworkProcess, MiniBrowser

PORT_NAME=webkitgtk
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

WEBKIT_SOURCE="$ROOT/ports/src/webkit"
PATCH_DIR="$ROOT/ports/src/patches/webkit"

SRC=${WEBKIT_SRC_DIR:-/var/tmp/tunix-webkit-src}
BUILD=${WEBKIT_BUILD_DIR:-/var/tmp/tunix-webkit-build}
ROOT_DIR="$OUT/webkitgtk-root"
CMAKE_FILE="$OUT/tunix-cmake-cross.cmake"

# 12 cores would be the right -j if RAM allowed; at ~1.5 GB per WebCore TU
# the WSL VM's memory is the binding constraint.
WEBKIT_JOBS=${WEBKIT_JOBS:-5}

EXPECTED_WEBKIT_VERSION=2.44.4

[[ -f "$WEBKIT_SOURCE/Source/cmake/OptionsGTK.cmake" ]] || cross_port_fail \
    "missing $WEBKIT_SOURCE; run git submodule update --init ports/src/webkit"

cross_port_require_toolchain
cross_port_require_tools cmake ninja pkg-config perl python3 ruby gperf unifdef \
    rsync "$READELF"

webkit_version=$(sed -n 's/^SET_PROJECT_VERSION(\([0-9]*\) \([0-9]*\) \([0-9]*\)).*/\1.\2.\3/p' \
    "$WEBKIT_SOURCE/Source/cmake/OptionsGTK.cmake" | head -n1)
[[ "$webkit_version" == "$EXPECTED_WEBKIT_VERSION" ]] || \
    cross_port_fail "expected webkit $EXPECTED_WEBKIT_VERSION, found ${webkit_version:-unknown}"

# Everything WebKit's cmake will go looking for.
for module in glib-2.0 gio-2.0 gtk+-3.0 libsoup-2.4 libpsl icu-uc icu-i18n \
              harfbuzz harfbuzz-icu libxml-2.0 libxslt sqlite3 libwebp \
              libwebpdemux libwoff2dec libbrotlidec gpg-error libgcrypt \
              libtasn1 libjpeg libpng epoxy fontconfig freetype2 cairo \
              wayland-client wayland-egl xkbcommon egl zlib; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

# --- stage the source on native ext4 -------------------------------------
# The test suites are most of the checkout by weight and play no part in
# building the library; leaving them behind halves the copy.
mkdir -p "$SRC"
rsync -a --delete --exclude=.git --exclude=LayoutTests --exclude=JSTests \
    --exclude=PerformanceTests --exclude=ManualTests --exclude=WebDriverTests \
    --exclude=WebKitLibraries --exclude=Websites \
    "$WEBKIT_SOURCE/" "$SRC/"
if compgen -G "$PATCH_DIR/*.patch" > /dev/null; then
    for patch_file in "$PATCH_DIR"/*.patch; do
        patch -p1 -d "$SRC" --fuzz=0 --forward < "$patch_file" || \
            cross_port_fail "failed to apply $(basename "$patch_file")"
    done
fi

rm -rf "$ROOT_DIR"
mkdir -p "$ROOT_DIR"

cross_port_write_cmake_toolchain "$CMAKE_FILE"
cross_port_export_pkg_config

# WebKit's Find modules are pkg-config driven; confine them to the sysroot.
# (meson gets this from the cross file; cmake needs the environment.)
export PKG_CONFIG_LIBDIR="$GRAPHICS_SYSROOT/usr/lib/pkgconfig:$GRAPHICS_SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$GRAPHICS_SYSROOT"
# wayland-protocols.pc advertises a host path already; the sysroot export
# above would double it (see patch 0002). State the datadir outright.
export WAYLAND_PROTOCOLS_DATADIR="$GRAPHICS_SYSROOT/usr/share/wayland-protocols"

cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-O2 -g0" \
    -DCMAKE_CXX_FLAGS="-O2 -g0" \
    -DPORT=GTK \
    -DUSE_GTK4=OFF \
    -DUSE_SOUP2=ON \
    -DENABLE_WAYLAND_TARGET=ON \
    -DENABLE_X11_TARGET=OFF \
    -DENABLE_QUARTZ_TARGET=OFF \
    -DENABLE_JIT=OFF \
    -DENABLE_C_LOOP=ON \
    -DENABLE_WEBASSEMBLY=OFF \
    -DENABLE_SAMPLING_PROFILER=OFF \
    -DUSE_SYSTEM_MALLOC=ON \
    -DENABLE_VIDEO=OFF \
    -DENABLE_WEB_AUDIO=OFF \
    -DENABLE_MEDIA_STREAM=OFF \
    -DENABLE_MEDIA_RECORDER=OFF \
    -DENABLE_ENCRYPTED_MEDIA=OFF \
    -DENABLE_WEB_RTC=OFF \
    -DENABLE_WEB_CODECS=OFF \
    -DENABLE_WEBGL=OFF \
    -DENABLE_GPU_PROCESS=OFF \
    -DENABLE_SPELLCHECK=OFF \
    -DENABLE_GAMEPAD=OFF \
    -DENABLE_SPEECH_SYNTHESIS=OFF \
    -DENABLE_BUBBLEWRAP_SANDBOX=OFF \
    -DENABLE_JOURNALD_LOG=OFF \
    -DENABLE_INTROSPECTION=OFF \
    -DENABLE_DOCUMENTATION=OFF \
    -DENABLE_WEBDRIVER=OFF \
    -DENABLE_MINIBROWSER=ON \
    -DENABLE_API_TESTS=OFF \
    -DUSE_LCMS=OFF \
    -DUSE_LIBBACKTRACE=OFF \
    -DUSE_LIBDRM=OFF \
    -DUSE_GBM=OFF \
    -DUSE_LIBHYPHEN=OFF \
    -DUSE_LIBSECRET=OFF \
    -DUSE_WOFF2=ON \
    -DUSE_JPEGXL=OFF \
    -DUSE_AVIF=OFF \
    2>&1 | tail -30

ninja -C "$BUILD" -j "$WEBKIT_JOBS"

DESTDIR="$GRAPHICS_SYSROOT" ninja -C "$BUILD" install > /dev/null
DESTDIR="$ROOT_DIR" ninja -C "$BUILD" install > /dev/null

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/webkit2gtk-4.0.pc" ]] || \
    cross_port_fail "webkit2gtk-4.0.pc was not installed"

for spec in "libwebkit2gtk-4.0.so.37:libwebkit2gtk-4.0.so.37" \
            "libjavascriptcoregtk-4.0.so.18:libjavascriptcoregtk-4.0.so.18"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done
for helper in WebKitWebProcess WebKitNetworkProcess MiniBrowser; do
    [[ -x "$ROOT_DIR/usr/libexec/webkit2gtk-4.0/$helper" ]] || \
        cross_port_fail "$helper was not installed"
done

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/gir-1.0" \
       "$ROOT_DIR/usr/share/man" "$ROOT_DIR/usr/share/doc" \
       "$ROOT_DIR/usr/share/locale"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
find "$ROOT_DIR/usr/libexec" -type f -exec "$CROSS_STRIP" --strip-all {} + 2>/dev/null || true

cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/gtk3-root" "$OUT/glib-root" \
    "$OUT/pango-root" "$OUT/gdk-pixbuf-root" "$OUT/cairo-root" "$OUT/wayland-root" \
    "$OUT/libxkbcommon-root" "$OUT/mesa-root" "$OUT/libdrm-root" "$OUT/pixman-root" \
    "$OUT/libffi-root" "$OUT/icu-root" "$OUT/libxml2-root" "$OUT/sqlite-root" \
    "$OUT/libwebp-root" "$OUT/woff2-root" "$OUT/libgcrypt-root" \
    "$OUT/libtasn1-root" "$OUT/libsoup-root" "$OUT/image-codecs-shared-root" \
    "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'webkitgtk %s staged at %s (%s)\n' "$webkit_version" "$ROOT_DIR" "$size"
