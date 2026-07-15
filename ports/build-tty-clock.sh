#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TTY_CLOCK_SOURCE="$ROOT/ports/src/tty-clock"
OUT=${OUT:-$ROOT/ports/out}
SYSROOT="$OUT/sysroot"
MUSL_CC="$SYSROOT/usr/bin/musl-gcc"
NCURSES_ROOT="$OUT/ncurses-root"
BUILD="$OUT/tty-clock-build"
TTY_CLOCK_BINARY="$OUT/tty-clock"

fail() {
    echo "build-tty-clock: $*" >&2
    exit 1
}

[[ -f "$TTY_CLOCK_SOURCE/ttyclock.c" ]] || fail "missing tty-clock source; initialize submodules"
[[ -x "$MUSL_CC" ]] || fail "missing Tunix musl toolchain; build Bash first"
[[ -f "$NCURSES_ROOT/usr/lib/libncursesw.a" ]] || fail "ncursesw was not built"
[[ -d "$NCURSES_ROOT/usr/share/terminfo" ]] || fail "Tunix terminfo database was not built"

NO_AUTO_ATOMIC=""
probe=$(mktemp)
trap 'rm -f "$probe" "$probe.o"' EXIT
printf 'int tunix_probe;\n' > "$probe"
if "$MUSL_CC" -fno-link-libatomic -x c -c "$probe" -o "$probe.o" >/dev/null 2>&1; then
    NO_AUTO_ATOMIC="-fno-link-libatomic"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

NCURSES_LIBS="-lncursesw"
if [[ -f "$NCURSES_ROOT/usr/lib/libtinfow.a" ]]; then
    NCURSES_LIBS="$NCURSES_LIBS -ltinfow"
fi

"$MUSL_CC" \
    -Os -Wall -fno-stack-protector -fno-pie $NO_AUTO_ATOMIC \
    -D_GNU_SOURCE \
    -I"$NCURSES_ROOT/usr/include" -I"$NCURSES_ROOT/usr/include/ncursesw" \
    -static -no-pie $NO_AUTO_ATOMIC -L"$NCURSES_ROOT/usr/lib" \
    -o "$BUILD/tty-clock" \
    "$TTY_CLOCK_SOURCE/ttyclock.c" \
    $NCURSES_LIBS \
    || fail "compilation failed"

[[ -x "$BUILD/tty-clock" ]] || fail "tty-clock binary was not produced"
cp "$BUILD/tty-clock" "$TTY_CLOCK_BINARY"
chmod 0755 "$TTY_CLOCK_BINARY"

if command -v readelf >/dev/null 2>&1; then
    if readelf -l "$TTY_CLOCK_BINARY" | grep -q 'INTERP'; then
        fail "tty-clock unexpectedly contains a dynamic interpreter"
    fi
    if readelf -d "$TTY_CLOCK_BINARY" 2>/dev/null | grep -q 'NEEDED'; then
        fail "tty-clock unexpectedly contains dynamic dependencies"
    fi
fi

version_output=$("$TTY_CLOCK_BINARY" -v 2>&1 || true)
[[ "$version_output" == *"TTY-Clock"* ]] || \
    fail "built tty-clock did not report its version correctly, got: ${version_output:-<empty>}"

printf '%s\n' 'tty-clock static binary is ready.'
