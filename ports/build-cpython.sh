#!/usr/bin/env bash
set -euo pipefail

# Build CPython for Tunix.
#
# Python is the largest single jump in what the machine can be asked to do, and
# it is also the most demanding test of the syscall surface there is: threads,
# signals, subprocess, epoll, mmap and dynamic loading, all in one program.
#
# Shared rather than static, unlike the GNU userland ports. A static build is
# far easier to produce, but it can never dlopen anything -- which costs ctypes
# and every third-party C extension, i.e. most of the reason to have Python.
#
# What is deliberately absent:
#   _ssl, _hashlib   no OpenSSL on Tunix (the TLS stack is GnuTLS). hashlib
#                    falls back to CPython's own md5/sha1/sha2/sha3/blake2.
#   _decimal         3.14 dropped the bundled libmpdec; decimal uses the pure
#                    Python implementation instead.
#   readline, curses ncurses is a static port and not in the graphics sysroot.
#                    3.13 onwards has PyREPL, which needs neither.
#   tkinter, idle    no Tcl/Tk.

PORT_NAME=cpython
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/cpython"
BUILD="$OUT/cpython-build"
ROOT_DIR="$OUT/cpython-root"

EXPECTED_VERSION=3.14.6
PYTHON_SERIES=3.14
version=$(sed -n 's/^#define PY_VERSION *"\([^"]*\)".*/\1/p' "$SOURCE/Include/patchlevel.h")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "expected CPython $EXPECTED_VERSION, found ${version:-unknown}"

cross_port_require_toolchain
cross_port_require_tools pkg-config python3 "$READELF"
for module in libffi zlib sqlite3 expat; do
    [[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/$module.pc" ]] || cross_port_fail \
        "$module is not in the graphics sysroot; build its port first"
done

# Cross-building CPython needs a working interpreter of the *same* series to
# run the freeze and bytecode steps. Nothing else will do -- the marshalled
# bytecode format is version-specific.
build_python_series=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
[[ "$build_python_series" == "$PYTHON_SERIES" ]] || cross_port_fail \
    "the host python3 is $build_python_series; CPython $PYTHON_SERIES needs a $PYTHON_SERIES build interpreter"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_autotools_setup

# --host puts autoconf in cross mode, where it cannot run its probe programs
# and falls back to guesses. These three are the ones whose guesses are wrong
# for Tunix: it has a /dev/ptmx, it has no /dev/ptc, and its getaddrinfo is
# fine (the "buggy" default assumes the worst and disables IPv6 name lookups).
cat > "$BUILD/config.site" <<'EOF_SITE'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
EOF_SITE
export CONFIG_SITE="$BUILD/config.site"

cross_port_configure "$SOURCE" "$BUILD" \
    --libdir=/usr/lib \
    --enable-shared \
    --without-static-libpython \
    --with-build-python=python3 \
    --with-system-expat \
    --with-ensurepip=no \
    --disable-test-modules

make -C "$BUILD" -j"$JOBS"
make -C "$BUILD" install DESTDIR="$ROOT_DIR"

[[ -x "$ROOT_DIR/usr/bin/python$PYTHON_SERIES" ]] || cross_port_fail "python was not installed"
[[ -f "$ROOT_DIR/usr/lib/libpython$PYTHON_SERIES.so.1.0" ]] || \
    cross_port_fail "libpython was not installed"

LIBDIR="$ROOT_DIR/usr/lib/python$PYTHON_SERIES"
# The modules worth asserting: without them Python starts but cannot do the
# things it was ported for.
for module in _socket _ctypes select fcntl _sqlite3 zlib pyexpat; do
    compgen -G "$LIBDIR/lib-dynload/$module.*.so" > /dev/null || \
        cross_port_fail "the $module extension was not built"
done

# The test suite is a third of the tree and nothing on the image runs it; the
# rest is either unbuildable here or build-time only.
rm -rf "$LIBDIR/test" "$LIBDIR/idlelib" "$LIBDIR/tkinter" "$LIBDIR/turtledemo" \
       "$LIBDIR/pydoc_data" "$LIBDIR/ensurepip" \
       "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share/man"
# config-*/ holds the makefiles for building C extensions against this Python.
# There is no compiler on the image that could use them, and python3-config
# reads them -- so both go. idle needs the idlelib removed above, and Tk.
rm -rf "$LIBDIR"/config-* \
       "$ROOT_DIR"/usr/bin/idle3 "$ROOT_DIR"/usr/bin/idle3.* \
       "$ROOT_DIR"/usr/bin/python3-config "$ROOT_DIR"/usr/bin/python3.*-config
find "$LIBDIR" -depth -name '__pycache__' -path '*/test*' -exec rm -rf {} + 2>/dev/null || true
# `make install` compiles the whole library three times, once per optimization
# level, and the two optimized copies are 22 MiB of bytecode that only
# `python -O` would ever load. Nothing on the image runs Python that way.
find "$LIBDIR" -name '*.opt-[12].pyc' -delete

cross_port_finalize_root "$ROOT_DIR"
# Python itself only needs libffi, libsqlite3, libz and libexpat. The list is
# longer than that because the check verifies every library in every root it is
# given, and libexpat is shipped by the cairo port -- so cairo's own
# dependencies have to be on the list to satisfy the walk over cairo.
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/libffi-root" \
    "$OUT/sqlite-root" "$OUT/cairo-root" "$OUT/pixman-root" "$OUT/libX11-root" \
    "$OUT/xcb-root" "$OUT/xext-root" "$OUT/fontstack-root" \
    "$OUT/image-codecs-shared-root" "$OUT/musl-shared-root" "$OUT/glib-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'CPython %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
