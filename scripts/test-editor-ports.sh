#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

ITERATIONS=${ITERATIONS:-20}
OUT="$ROOT/ports/out"
NANO="$OUT/nano"
TERMINFO="$OUT/ncurses-root/usr/share/terminfo"

for script in ports/build-ncurses.sh ports/build-nano.sh; do
    bash -n "$script"
done
python3 -m py_compile scripts/nano-smoke.py scripts/nano-qemu-smoke.py

HOST_CC=${HOST_CC:-cc}
TTY_TEST=$(mktemp "${TMPDIR:-/tmp}/tunix-tty-test.XXXXXX")
trap 'rm -f "$TTY_TEST"' EXIT
"$HOST_CC" -std=c11 -Wall -Wextra -Werror -Isrc/kernel \
    scripts/tty-keyboard-test.c -o "$TTY_TEST"
"$TTY_TEST"

make ports/out/nano

[[ -x "$NANO" ]] || { echo "nano binary is missing" >&2; exit 1; }
[[ -d "$TERMINFO" ]] || { echo "terminfo database is missing" >&2; exit 1; }

if command -v readelf >/dev/null 2>&1; then
    ! readelf -l "$NANO" | grep -q INTERP
    ! readelf -d "$NANO" 2>/dev/null | grep -q NEEDED
fi

TERM=tunix-256color TERMINFO="$TERMINFO" "$NANO" --version
python3 scripts/nano-smoke.py "$NANO" "$TERMINFO" --iterations "$ITERATIONS"
