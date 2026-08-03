#!/usr/bin/env bash
set -euo pipefail

# Build alsa-lib for Tunix.
#
# This is the userspace half of the sound driver: the kernel speaks ALSA's
# ioctl protocol on /dev/snd, and alsa-lib is what turns that into an API
# anything else can use. It is also the reason the kernel side was written to
# Linux's ABI rather than to something of our own -- PipeWire has no other
# backend for a PCI sound card, and PipeWire is where this is heading.
#
# Two configure decisions are not defaults:
#
#   --disable-topology drops libatopology, which loads DSP topology blobs for
#   SoC cards. Nothing here has one.
#
#   Everything else stays on, mixer/seq/rawmidi/hwdep/ucm included, even though
#   the kernel implements only some of it. PipeWire's ALSA plugin references
#   those symbols at link time; a library missing them fails to link long
#   before anything discovers the device is not there.
#
# dmix cannot work here and this port does not pretend otherwise: it mixes
# through SysV shared memory and semaphores, which Tunix has no syscalls for.
# initrd/etc/asound.conf points `default` at plug:hw:0 instead -- the override
# ALSA itself provides for this. Software mixing is PipeWire's job anyway.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for PipeWire later
#   $OUT/alsa-lib-root/usr/lib                libasound.so.2 for the image
#   $OUT/alsa-lib-root/usr/share/alsa         the configuration tree it reads
#   $OUT/alsa-lib-root/usr/bin/alsa-test      the acceptance test

PORT_NAME=alsa-lib
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/alsa-lib"
BUILD="$OUT/alsa-lib-build"
ROOT_DIR="$OUT/alsa-lib-root"
TEST_SOURCE="$ROOT/tools/alsa-test.c"

EXPECTED_VERSION=1.2.16.1

[[ -f "$SOURCE/configure.ac" ]] || cross_port_fail \
    "missing alsa-lib source at $SOURCE; run git submodule update --init --recursive"
[[ -f "$TEST_SOURCE" ]] || cross_port_fail "missing $TEST_SOURCE"

cross_port_require_toolchain
cross_port_require_tools pkg-config autoreconf libtoolize gcc "$READELF"

version=$(sed -n 's/^AC_INIT(\[alsa-lib\], \[\([^]]*\)\].*/\1/p' "$SOURCE/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected alsa-lib $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_autotools_setup

# autoreconf on a copy, so ports/src stays clean.
tar -C "$SOURCE" --exclude=.git -cf - . | { mkdir -p "$BUILD/src"; tar -C "$BUILD/src" -xf -; }
( cd "$BUILD/src" && autoreconf -fi >/dev/null 2>&1 )

( cd "$BUILD/src" && ./configure \
    --host="$CROSS_TARGET" --build="$(gcc -dumpmachine)" \
    --prefix=/usr --libdir=/usr/lib \
    --disable-static --enable-shared \
    --disable-python \
    --disable-topology \
    --disable-alisp \
    --disable-resmgr \
    --disable-aload \
    --without-debug \
    --with-configdir=/usr/share/alsa \
    --with-plugindir=/usr/lib/alsa-lib \
    --with-pkgconfdir=/usr/lib/pkgconfig )

make -C "$BUILD/src" -j "$JOBS"
make -C "$BUILD/src" DESTDIR="$GRAPHICS_SYSROOT" install
make -C "$BUILD/src" DESTDIR="$ROOT_DIR" install

find "$GRAPHICS_SYSROOT/usr/lib" -name '*.la' -delete

[[ -f "$GRAPHICS_SYSROOT/usr/include/alsa/asoundlib.h" ]] || \
    cross_port_fail "alsa headers were not installed into the graphics sysroot"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/alsa.pc" ]] || \
    cross_port_fail "alsa.pc was not installed into the graphics sysroot"

shared=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libasound.so.2*' -print -quit)
[[ -n "$shared" ]] || cross_port_fail "libasound was not installed"
cross_port_check_library "$shared" libasound.so.2

# The configuration tree is not optional decoration: snd_pcm_open() resolves
# every device name through it, so a library without it can only open the
# nothing-device.
[[ -f "$ROOT_DIR/usr/share/alsa/alsa.conf" ]] || \
    cross_port_fail "the alsa configuration tree was not installed"
[[ -f "$ROOT_DIR/usr/share/alsa/pcm/default.conf" ]] || \
    cross_port_fail "the default PCM definition is missing"

# The acceptance test, dynamically linked against what we just built. It is the
# only thing here that proves the library and the driver agree.
mkdir -p "$ROOT_DIR/usr/bin"
TEST_BINARY="$ROOT_DIR/usr/bin/alsa-test"
"$CROSS_CC" -std=gnu11 -Wall -Wextra -Werror -O2 -fPIE -pie \
    -I"$GRAPHICS_SYSROOT/usr/include" \
    "$TEST_SOURCE" \
    -L"$GRAPHICS_SYSROOT/usr/lib" \
    -Wl,-rpath-link,"$GRAPHICS_SYSROOT/usr/lib" \
    -lasound \
    -o "$TEST_BINARY"
chmod 0755 "$TEST_BINARY"

needed=$("$READELF" -d "$TEST_BINARY" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
grep -Fxq libasound.so.2 <<<"$needed" || \
    cross_port_fail "alsa-test does not link against libasound.so.2"
interpreter=$("$READELF" -l "$TEST_BINARY" | \
    sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
[[ "$interpreter" == "/lib/ld-musl-x86_64.so.1" ]] || \
    cross_port_fail "alsa-test asks for interpreter '${interpreter:-none}'"

# Load it here, with the target loader, before believing any of it. The build
# host has no sound card, so the test cannot pass -- but getting as far as
# printing the library version proves every relocation resolved, which is the
# failure this catches and a boot would only reveal much later.
banner=$("$CROSS_LOADER" --library-path "$ROOT_DIR/usr/lib" "$TEST_BINARY" 2>&1 | head -n1 || true)
[[ "$banner" == "alsa-test: alsa-lib $version"* ]] || \
    cross_port_fail "alsa-test did not load: ${banner:-no output}"

# aserver serves a PCM to other machines over a socket. Nothing here wants it.
rm -f "$ROOT_DIR/usr/bin/aserver"
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" \
       "$ROOT_DIR/usr/share/aclocal"
find "$ROOT_DIR/usr/lib" -name '*.la' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$TEST_BINARY"
chmod 0755 "$TEST_BINARY"
cross_port_check_runtime_closure "$ROOT_DIR"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'alsa-lib %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
