#!/usr/bin/env bash
set -euo pipefail

# SDL2 for Tunix. X11 video + ALSA audio, everything else off.
#
# No GL of any kind: mesa is built with -Dplatforms= and the X server with
# -Dglx=false, so there is no way to get a context onto a window. Asking SDL for
# one would only fail later, at SDL_GL_CreateContext, inside whatever game we
# port. Disabled here it advertises the software renderer and nothing else.
#
# --disable-x11-shared / --disable-alsa-shared: SDL would otherwise dlopen these
# by SONAME and silently drop the whole subsystem if the open failed. Linking
# them makes cross_port_check_runtime_closure the thing that catches it.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + sdl2.pc for SDL_mixer etc
#   $OUT/sdl2-root/usr/lib                    libSDL2-2.0.so.0 for the image
#   $OUT/sdl2-root/usr/bin/sdl2-test          the acceptance test

PORT_NAME=SDL2
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/SDL2"
PATCH_DIR="$ROOT/ports/src/patches/SDL2"
BUILD="$OUT/sdl2-build"
ROOT_DIR="$OUT/sdl2-root"
TEST_SOURCE="$ROOT/tools/sdl2-test.c"

EXPECTED_VERSION=2.32.10

[[ -f "$SOURCE/configure" ]] || cross_port_fail \
    "missing SDL2 source at $SOURCE; run git submodule update --init"
[[ -f "$TEST_SOURCE" ]] || cross_port_fail "missing $TEST_SOURCE"

cross_port_require_toolchain
cross_port_require_tools pkg-config gcc "$READELF"

for pc in x11 xext xcursor xi xrandr xfixes alsa; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc is not in the sysroot; build its port first"
done

version=$(sed -n 's/^#define SDL_\(MAJOR_VERSION\|MINOR_VERSION\|PATCHLEVEL\) *//p' \
    "$SOURCE/include/SDL_version.h" | paste -sd. -)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected SDL $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/src" "$BUILD/obj" "$ROOT_DIR"

tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/src" -xf -
patches=("$PATCH_DIR"/*.patch)
[[ -e "${patches[0]}" ]] || cross_port_fail "no patches found in $PATCH_DIR"
for patch in "${patches[@]}"; do
    patch -p1 -d "$BUILD/src" --fuzz=0 --forward < "$patch" ||
        cross_port_fail "failed to apply $(basename "$patch")"
done

cross_port_autotools_setup

cross_port_configure "$BUILD/src" "$BUILD/obj" \
    --libdir=/usr/lib \
    --disable-rpath \
    --enable-video-x11 --disable-x11-shared \
    --enable-video-x11-xcursor --enable-video-x11-xinput \
    --enable-video-x11-xfixes --enable-video-x11-xrandr \
    --enable-video-x11-xshape --enable-video-x11-xdbe \
    --disable-video-x11-scrnsaver \
    --disable-video-wayland \
    --disable-video-kmsdrm \
    --disable-video-directfb \
    --disable-video-opengl --disable-video-opengles --disable-video-vulkan \
    --enable-alsa --disable-alsa-shared --disable-alsatest \
    --disable-oss --disable-jack --disable-pipewire --disable-pulseaudio \
    --disable-sndio --disable-esd --disable-arts --disable-nas \
    --disable-fusionsound --disable-libsamplerate \
    --enable-libudev \
    --disable-dbus --disable-ibus --disable-fcitx \
    --disable-hidapi \
    --enable-joystick --enable-loadso

make -C "$BUILD/obj" -j "$JOBS"
make -C "$BUILD/obj" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD/obj" DESTDIR="$ROOT_DIR" install

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/include/SDL2/SDL.h" ]] || \
    cross_port_fail "the SDL headers were not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/sdl2.pc" ]] || \
    cross_port_fail "sdl2.pc was not installed into the graphics sysroot"

shared=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libSDL2-2.0.so.0*' -print -quit)
[[ -n "$shared" ]] || cross_port_fail "libSDL2 was not installed"
cross_port_check_library "$shared" libSDL2-2.0.so.0

"$READELF" -d "$shared" | grep -q 'Shared library: \[libX11\.so\.6\]' || \
    cross_port_fail "libSDL2 is not linked against libX11; the x11 video driver was dropped"
"$READELF" -d "$shared" | grep -q 'Shared library: \[libasound\.so\.2\]' || \
    cross_port_fail "libSDL2 is not linked against libasound; the alsa audio driver was dropped"

mkdir -p "$ROOT_DIR/usr/bin"
TEST_BINARY="$ROOT_DIR/usr/bin/sdl2-test"
"$CROSS_CC" -std=gnu11 -Wall -Wextra -Werror -O2 -fPIE -pie \
    -I"$GRAPHICS_SYSROOT/usr/include/SDL2" -D_REENTRANT \
    "$TEST_SOURCE" \
    -L"$GRAPHICS_SYSROOT/usr/lib" \
    -Wl,-rpath-link,"$GRAPHICS_SYSROOT/usr/lib" \
    -lSDL2 -lm \
    -o "$TEST_BINARY"
chmod 0755 "$TEST_BINARY"

interpreter=$("$READELF" -l "$TEST_BINARY" | \
    sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
[[ "$interpreter" == "/lib/ld-musl-x86_64.so.1" ]] || \
    cross_port_fail "sdl2-test asks for interpreter '${interpreter:-none}'"

# Loading it here proves every relocation resolved. The build host has no X
# display, so --drivers stops before SDL_Init.
libpath="$ROOT_DIR/usr/lib:$GRAPHICS_SYSROOT/usr/lib"
banner=$("$CROSS_LOADER" --library-path "$libpath" "$TEST_BINARY" --drivers 2>&1 || true)
grep -Fxq "sdl2-test: SDL $version" <<<"$banner" || \
    cross_port_fail "sdl2-test did not load: ${banner:-no output}"
grep -q '^sdl2-test: video drivers:.* x11' <<<"$banner" || \
    cross_port_fail "the x11 video driver is not registered: ${banner}"
grep -q '^sdl2-test: audio drivers:.* alsa' <<<"$banner" || \
    cross_port_fail "the alsa audio driver is not registered: ${banner}"

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/aclocal"
rm -f "$ROOT_DIR/usr/bin/sdl2-config"
find "$ROOT_DIR/usr/lib" \( -name '*.la' -o -name '*.a' \) -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$TEST_BINARY"
chmod 0755 "$TEST_BINARY"
cross_port_check_runtime_closure "$ROOT_DIR" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root" \
    "$OUT/alsa-lib-root" "$OUT/libudev-zero-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'SDL2 %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
