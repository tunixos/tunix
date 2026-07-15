#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TTY_TETRIS_SOURCE="$ROOT/ports/src/tty-tetris"
OUT=${OUT:-$ROOT/ports/out}
SYSROOT="$OUT/sysroot"
MUSL_CC="$SYSROOT/usr/bin/musl-gcc"
BUILD="$OUT/tty-tetris-build"
TTY_TETRIS_BINARY="$OUT/tty-tetris"

fail() {
    echo "build-tty-tetris: $*" >&2
    exit 1
}

[[ -f "$TTY_TETRIS_SOURCE/tetris.c" ]] || fail "missing tty-tetris source; initialize submodules"
[[ -x "$MUSL_CC" ]] || fail "missing Tunix musl toolchain; build Bash first"

NO_AUTO_ATOMIC=""
probe=$(mktemp)
trap 'rm -f "$probe" "$probe.o"' EXIT
printf 'int tunix_probe;\n' > "$probe"
if "$MUSL_CC" -fno-link-libatomic -x c -c "$probe" -o "$probe.o" >/dev/null 2>&1; then
    NO_AUTO_ATOMIC="-fno-link-libatomic"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/source"
cp "$TTY_TETRIS_SOURCE"/*.c "$TTY_TETRIS_SOURCE"/*.h "$BUILD/source/"

# Upstream bug: frame_nextbox_init/refresh index the array up to
# [FRAMEH_NB][FRAMEW_NB] inclusive, but the declaration is one row and one
# column short. The 64-byte overflow lands on the adjacent 'tv' itimerval
# global in this static musl layout and kills the SIGALRM gravity timer.
# Upstream already sizes 'frame' with +1; apply the same to frame_nextbox.
grep -q 'int frame_nextbox\[FRAMEH_NB\]\[FRAMEW_NB\];' "$BUILD/source/tetris.h" || \
    fail "tetris.h frame_nextbox declaration changed upstream; re-check the overflow fix"
sed -i 's/int frame_nextbox\[FRAMEH_NB\]\[FRAMEW_NB\];/int frame_nextbox[FRAMEH_NB + 1][FRAMEW_NB + 1];/' \
    "$BUILD/source/tetris.h"

"$MUSL_CC" \
    -Os -Wall -fno-stack-protector -fno-pie -fcommon $NO_AUTO_ATOMIC \
    -D_GNU_SOURCE \
    -static -no-pie $NO_AUTO_ATOMIC \
    -o "$BUILD/tty-tetris" \
    "$BUILD/source/util.c" \
    "$BUILD/source/frame.c" \
    "$BUILD/source/shapes.c" \
    "$BUILD/source/tetris.c" \
    || fail "compilation failed"

[[ -x "$BUILD/tty-tetris" ]] || fail "tty-tetris binary was not produced"
cp "$BUILD/tty-tetris" "$TTY_TETRIS_BINARY"
chmod 0755 "$TTY_TETRIS_BINARY"

if command -v readelf >/dev/null 2>&1; then
    if readelf -l "$TTY_TETRIS_BINARY" | grep -q 'INTERP'; then
        fail "tty-tetris unexpectedly contains a dynamic interpreter"
    fi
    if readelf -d "$TTY_TETRIS_BINARY" 2>/dev/null | grep -q 'NEEDED'; then
        fail "tty-tetris unexpectedly contains dynamic dependencies"
    fi
fi

printf '%s\n' 'tty-tetris static binary is ready.'
