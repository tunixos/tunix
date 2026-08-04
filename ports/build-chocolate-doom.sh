#!/usr/bin/env bash
set -euo pipefail

# Chocolate Doom for Tunix, plus the Freedoom IWAD to run it on.
#
# Nothing in the source is patched: it wants SDL2, SDL2_mixer and SDL2_net,
# which are now all here, and it renders through SDL_Renderer, which on this
# system resolves to the software renderer.
#
# Music works without a timidity patch set because Chocolate Doom carries its
# own OPL3 emulator and reads GENMIDI from the IWAD, so it never asks
# SDL2_mixer to synthesise MIDI.
#
# Only the Doom binaries are staged. Heretic, Hexen and Strife build from the
# same tree but have no IWAD here, and the root filesystem lives in RAM.
#
# freedoom1.wad only, for the same reason: it is a complete four-episode game
# at 28 MiB, and freedoom2.wad would add another 28 MiB to an initramfs that
# has to fit under the kernel's 1 GiB direct-map ceiling.
#
# Output:
#   $OUT/chocolate-doom-root/usr/bin                   chocolate-doom, -setup, -server
#   $OUT/chocolate-doom-root/usr/share/games/doom      freedoom1.wad

PORT_NAME=chocolate-doom
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/chocolate-doom"
BUILD="$OUT/chocolate-doom-build"
ROOT_DIR="$OUT/chocolate-doom-root"

EXPECTED_VERSION=3.1.1

FREEDOOM_VERSION=0.13.0
FREEDOOM_SHA256=3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59
FREEDOOM_URL="https://github.com/freedoom/freedoom/releases/download/v$FREEDOOM_VERSION/freedoom-$FREEDOOM_VERSION.zip"
FREEDOOM_CACHE=${FREEDOOM_CACHE:-/var/tmp/tunix-freedoom}
FREEDOOM_ZIP="$FREEDOOM_CACHE/freedoom-$FREEDOOM_VERSION.zip"

[[ -f "$SOURCE/configure.ac" ]] || cross_port_fail \
    "missing chocolate-doom source at $SOURCE; run git submodule update --init"

cross_port_require_toolchain
cross_port_require_tools pkg-config autoreconf libtoolize gcc python3 curl \
    sha256sum "$READELF"

for pc in sdl2 SDL2_mixer SDL2_net libpng; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$pc.pc" ]] || cross_port_fail \
        "$pc is not in the sysroot; build its port first"
done

version=$(sed -n 's/^AC_INIT(Chocolate Doom, \([^,]*\),.*/\1/p' "$SOURCE/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected Chocolate Doom $EXPECTED_VERSION, found ${version:-unknown}"

mkdir -p "$FREEDOOM_CACHE"
if [[ ! -f "$FREEDOOM_ZIP" ]]; then
    curl -sSL --max-time 900 -o "$FREEDOOM_ZIP.partial" "$FREEDOOM_URL" || \
        cross_port_fail "could not download $FREEDOOM_URL"
    mv "$FREEDOOM_ZIP.partial" "$FREEDOOM_ZIP"
fi
observed=$(sha256sum "$FREEDOOM_ZIP" | cut -d' ' -f1)
[[ "$observed" == "$FREEDOOM_SHA256" ]] || cross_port_fail \
    "freedoom-$FREEDOOM_VERSION.zip has SHA-256 $observed, expected $FREEDOOM_SHA256"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/src" "$BUILD/obj" "$ROOT_DIR"

# autoreconf on a copy: the repository ships no configure, and ports/src stays
# untouched.
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/src" -xf -
( cd "$BUILD/src" && autoreconf -fi >/dev/null 2>&1 )

cross_port_autotools_setup

cross_port_configure "$BUILD/src" "$BUILD/obj" \
    --libdir=/usr/lib \
    --without-libsamplerate \
    --disable-bash-completion \
    --disable-doc

make -C "$BUILD/obj" -j "$JOBS"
make -C "$BUILD/obj" DESTDIR="$ROOT_DIR" install

DOOM_BINARY="$ROOT_DIR/usr/bin/chocolate-doom"
[[ -x "$DOOM_BINARY" ]] || cross_port_fail "chocolate-doom was not installed"

interpreter=$("$READELF" -l "$DOOM_BINARY" | \
    sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
[[ "$interpreter" == "/lib/ld-musl-x86_64.so.1" ]] || \
    cross_port_fail "chocolate-doom asks for interpreter '${interpreter:-none}'"

needed=$("$READELF" -d "$DOOM_BINARY" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
for library in libSDL2-2.0.so.0 libSDL2_mixer-2.0.so.0 libSDL2_net-2.0.so.0; do
    grep -Fxq "$library" <<<"$needed" || \
        cross_port_fail "chocolate-doom does not link against $library"
done

# --version exits before SDL is touched, so the target loader can run it here.
# Proves every relocation across all three SDL libraries resolved.
libpath="$OUT/sdl2-root/usr/lib:$OUT/sdl2-mixer-root/usr/lib:$OUT/sdl2-net-root/usr/lib:$GRAPHICS_SYSROOT/usr/lib"
banner=$("$CROSS_LOADER" --library-path "$libpath" "$DOOM_BINARY" --version 2>&1 || true)
[[ "$banner" == "Chocolate Doom $version" ]] || \
    cross_port_fail "chocolate-doom did not load: ${banner:-no output}"

# The binaries, and everything that would leave a dead entry in the Xfce menu
# pointing at one of them.
for game in Heretic Hexen Strife; do
    lower=$(tr '[:upper:]' '[:lower:]' <<<"$game")
    rm -f "$ROOT_DIR/usr/bin/chocolate-$lower" \
          "$ROOT_DIR/usr/bin/chocolate-$lower-setup" \
          "$ROOT_DIR/usr/share/applications/org.chocolate_doom.$game.desktop" \
          "$ROOT_DIR/usr/share/metainfo/org.chocolate_doom.$game.metainfo.xml" \
          "$ROOT_DIR"/usr/share/icons/hicolor/*/apps/chocolate-"$lower".png
    rm -rf "$ROOT_DIR/usr/share/doc/chocolate-$lower"
done

WAD_DIR="$ROOT_DIR/usr/share/games/doom"
mkdir -p "$WAD_DIR"
python3 - "$FREEDOOM_ZIP" "$WAD_DIR" <<'PYTHON'
import sys, zipfile
archive, target = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as bundle:
    name = next(n for n in bundle.namelist() if n.endswith("/freedoom1.wad"))
    with bundle.open(name) as source, open(target + "/freedoom1.wad", "wb") as sink:
        sink.write(source.read())
PYTHON
[[ -s "$WAD_DIR/freedoom1.wad" ]] || cross_port_fail "freedoom1.wad was not extracted"
head -c 4 "$WAD_DIR/freedoom1.wad" | grep -q IWAD || \
    cross_port_fail "freedoom1.wad is not an IWAD"
chmod 0644 "$WAD_DIR/freedoom1.wad"

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$ROOT_DIR"/usr/bin/chocolate-* 2>/dev/null || true
chmod 0755 "$ROOT_DIR"/usr/bin/chocolate-*
cross_port_check_runtime_closure "$ROOT_DIR" \
    "$OUT/sdl2-root" "$OUT/sdl2-mixer-root" "$OUT/sdl2-net-root" \
    "$OUT/libX11-root" "$OUT/xext-root" "$OUT/xcb-root" \
    "$OUT/alsa-lib-root" "$OUT/libudev-zero-root" "$OUT/image-codecs-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'Chocolate Doom %s + Freedoom %s staged at %s (%s)\n' \
    "$version" "$FREEDOOM_VERSION" "$ROOT_DIR" "$size"
