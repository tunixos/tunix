#!/usr/bin/env bash
set -euo pipefail

# Build GLib for Tunix: pcre2, then glib itself.
#
# GLib is the ground floor of the GTK stack -- gobject, gio, gmain -- and the
# first thing here that exercises the kernel the way a desktop toolkit does:
# it spawns a worker thread on startup (CLONE_THREAD + futex), watches files
# with inotify, and multiplexes everything over epoll and eventfd. All of that
# exists in the kernel and is what glib-compat-test was written to prove.
#
# pcre2 is built here because GLib is its only consumer: GRegex wraps it and
# will not build without it. JIT stays off -- GRegex users on this system are
# not hot loops, and the JIT is the part of pcre2 with platform-specific
# assumptions worth not auditing.
#
# Choices that are load-bearing:
#
#   -Dnls=disabled     musl carries stub gettext; there is no libintl to link
#                      and nothing ships translations anyway.
#   -Dlibmount=disabled  gio uses it to watch mount tables; Tunix has no
#                      util-linux and /proc/mounts style watching is pointless
#                      on a system whose mounts never change.
#   -Dxattr=false      the kernel has no *xattr syscalls.
#   introspection off  needs a girepository host stack we do not have; nothing
#                      here consumes .typelib files.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for pango and gtk
#   $OUT/glib-root/usr/lib                    the shared libraries

PORT_NAME=glib
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

PCRE2_SOURCE="$ROOT/ports/src/pcre2"
GLIB_SOURCE="$ROOT/ports/src/glib"

BUILD="$OUT/glib-build"
ROOT_DIR="$OUT/glib-root"
CROSS_FILE="$OUT/tunix-meson-cross.ini"
CMAKE_FILE="$OUT/tunix-cmake-cross.cmake"

EXPECTED_PCRE2_VERSION=10.46
EXPECTED_GLIB_VERSION=2.84.4

for source in "$PCRE2_SOURCE/CMakeLists.txt" "$GLIB_SOURCE/meson.build"; do
    [[ -f "$source" ]] || cross_port_fail \
        "missing $source; run git submodule update --init --recursive"
done

cross_port_require_toolchain
cross_port_require_tools meson ninja cmake pkg-config python3 "$READELF"

glib_version=$(sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$GLIB_SOURCE/meson.build" | head -n1)
[[ "$glib_version" == "$EXPECTED_GLIB_VERSION" ]] || \
    cross_port_fail "expected glib $EXPECTED_GLIB_VERSION, found ${glib_version:-unknown}"

# GLib links zlib and libffi; both are already in the graphics sysroot (zlib
# from the cairo chain, libffi from the wayland bring-up).
for module in zlib libffi; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_write_meson_cross "$CROSS_FILE"
cross_port_write_cmake_toolchain "$CMAKE_FILE"
cross_port_export_pkg_config

install_both() {
    local build_dir="$1" kind="$2"
    case "$kind" in
        meson)
            DESTDIR="$GRAPHICS_SYSROOT" meson install -C "$build_dir" --no-rebuild
            DESTDIR="$ROOT_DIR" meson install -C "$build_dir" --no-rebuild
            ;;
        cmake)
            DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$build_dir"
            DESTDIR="$ROOT_DIR" cmake --install "$build_dir"
            ;;
    esac
}

# --- pcre2 ---------------------------------------------------------------
# The version lives in configure.ac as m4_define(pcre2_major, [10]) etc.;
# CMakeLists.txt reads it from there too.
pcre2_version=$(sed -n 's/^m4_define(pcre2_major, \[\([0-9]*\)\]).*/\1/p;s/^m4_define(pcre2_minor, \[\([0-9]*\)\]).*/\1/p' \
    "$PCRE2_SOURCE/configure.ac" 2>/dev/null | paste -sd. - || true)
[[ "$pcre2_version" == "$EXPECTED_PCRE2_VERSION" ]] || \
    cross_port_fail "expected pcre2 $EXPECTED_PCRE2_VERSION, found ${pcre2_version:-unknown}"

cmake -S "$PCRE2_SOURCE" -B "$BUILD/pcre2" -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE="$CMAKE_FILE" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-O2 -fPIC" \
    -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF \
    -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF \
    -DPCRE2_SUPPORT_UNICODE=ON -DPCRE2_SUPPORT_JIT=OFF \
    -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF
cmake --build "$BUILD/pcre2" --parallel "$JOBS"
install_both "$BUILD/pcre2" cmake
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libpcre2-8.pc" ]] || \
    cross_port_fail "libpcre2-8.pc was not installed"

# --- glib ----------------------------------------------------------------
meson setup "$BUILD/glib" "$GLIB_SOURCE" \
    --cross-file "$CROSS_FILE" \
    --prefix=/usr --libdir=lib --buildtype=release --default-library=shared \
    -Dintrospection=disabled \
    -Dnls=disabled \
    -Dselinux=disabled \
    -Dxattr=false \
    -Dlibmount=disabled \
    -Dman-pages=disabled \
    -Ddtrace=disabled \
    -Dsystemtap=disabled \
    -Dsysprof=disabled \
    -Ddocumentation=false \
    -Dtests=false \
    -Dinstalled_tests=false \
    -Dglib_debug=disabled \
    -Dlibelf=disabled
meson compile -C "$BUILD/glib" -j "$JOBS"
install_both "$BUILD/glib" meson

[[ -f "$GRAPHICS_SYSROOT/usr/include/glib-2.0/glib.h" ]] || \
    cross_port_fail "glib headers were not installed into the graphics sysroot"
for pc in glib-2.0 gobject-2.0 gio-2.0 gmodule-2.0 gthread-2.0; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || \
        cross_port_fail "$pc.pc was not installed into the graphics sysroot"
done

for spec in "libpcre2-8.so.0:libpcre2-8.so.0" "libglib-2.0.so.0:libglib-2.0.so.0" \
            "libgobject-2.0.so.0:libgobject-2.0.so.0" "libgio-2.0.so.0:libgio-2.0.so.0" \
            "libgmodule-2.0.so.0:libgmodule-2.0.so.0"; do
    name=${spec%%:*}
    soname=${spec##*:}
    library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name "$name*" -print -quit)
    [[ -n "$library" ]] || cross_port_fail "$name was not installed"
    cross_port_check_library "$library" "$soname"
done

# The developer tools (gdbus-codegen, glib-compile-resources and friends) are
# build-time programs; gio/gsettings/gdbus the runtime ones -- nothing on the
# image calls them and each drags in size. gio-querymodules would only matter
# if we shipped gio modules, which we do not.
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/bin" "$ROOT_DIR/usr/libexec" \
       "$ROOT_DIR/usr/share"
# glib 2.84 builds libgirepository unconditionally; without typelibs (and with
# introspection disabled everywhere) it is dead weight on the image. The
# sysroot copy stays, in case a later port's build wants the .pc.
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name 'libgirepository*' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/cairo-root" "$OUT/libffi-root" \
    "$OUT/pixman-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'glib %s (with pcre2 %s) staged at %s (%s)\n' \
    "$glib_version" "$pcre2_version" "$ROOT_DIR" "$size"
