#!/usr/bin/env bash
set -euo pipefail

# SDL2_mixer for Tunix. Only the decoders that ship inside SDL_mixer itself are
# enabled -- stb_vorbis, dr_flac, minimp3, the WAVE reader and the built-in
# timidity -- so this port pulls in no library that is not already here.
#
# Everything left out (opus, wavpack, xmp/modplug, gme, fluidsynth) wants an
# external decoder. music-cmd is off because it plays music by forking an
# external player, which is not a thing this image has.
#
# timidity is compiled in but has no patch set on the image, so MIDI (and
# therefore Doom's MUS music) will not sound until one is added. The alternative
# was disabling it, which would have made that a rebuild rather than a copy.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + SDL2_mixer.pc
#   $OUT/sdl2-mixer-root/usr/lib              libSDL2_mixer-2.0.so.0 for the image

PORT_NAME=SDL2_mixer
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/SDL2_mixer"
BUILD="$OUT/sdl2-mixer-build"
ROOT_DIR="$OUT/sdl2-mixer-root"

EXPECTED_VERSION=2.8.2

[[ -f "$SOURCE/configure" ]] || cross_port_fail \
    "missing SDL2_mixer source at $SOURCE; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools pkg-config gcc "$READELF"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/sdl2.pc" ]] || \
    cross_port_fail "sdl2.pc is not in the sysroot; build the SDL2 port first"

version=$(sed -n 's/^#define SDL_MIXER_\(MAJOR_VERSION\|MINOR_VERSION\|PATCHLEVEL\) *//p' \
    "$SOURCE/include/SDL_mixer.h" | paste -sd. -)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected SDL2_mixer $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/src" "$BUILD/obj" "$ROOT_DIR"

tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/src" -xf -
touch "$BUILD/src/configure" "$BUILD/src/Makefile.in"

cross_port_autotools_setup

cross_port_configure "$BUILD/src" "$BUILD/obj" \
    --libdir=/usr/lib \
    --disable-sdltest \
    --disable-rpath \
    --disable-music-cmd \
    --enable-music-wave \
    --disable-music-mod \
    --enable-music-midi --enable-music-midi-timidity \
    --disable-music-midi-fluidsynth --disable-music-midi-native \
    --disable-music-gme \
    --enable-music-ogg --enable-music-ogg-stb \
    --disable-music-ogg-vorbis --disable-music-ogg-tremor \
    --enable-music-flac --enable-music-flac-drflac --disable-music-flac-libflac \
    --enable-music-mp3 --enable-music-mp3-minimp3 --disable-music-mp3-mpg123 \
    --disable-music-opus \
    --disable-music-wavpack

make -C "$BUILD/obj" -j "$JOBS"
make -C "$BUILD/obj" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD/obj" DESTDIR="$ROOT_DIR" install

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/include/SDL2/SDL_mixer.h" ]] || \
    cross_port_fail "SDL_mixer.h was not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/SDL2_mixer.pc" ]] || \
    cross_port_fail "SDL2_mixer.pc was not installed into the graphics sysroot"

shared=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libSDL2_mixer-2.0.so.0*' -print -quit)
[[ -n "$shared" ]] || cross_port_fail "libSDL2_mixer was not installed"
cross_port_check_library "$shared" libSDL2_mixer-2.0.so.0

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/lib/cmake" "$ROOT_DIR/usr/share/aclocal"
find "$ROOT_DIR/usr/lib" \( -name '*.la' -o -name '*.a' \) -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/sdl2-root" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root" \
    "$OUT/alsa-lib-root" "$OUT/libudev-zero-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'SDL2_mixer %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
