#!/usr/bin/env bash
set -euo pipefail

# Build SQLite for Tunix. WebKit's storage layers (localStorage, IndexedDB,
# the HTTP cache metadata) sit on it, and the sqlite3 shell is a usable tool
# on the image in its own right.
#
# SQLite builds from the git tree with its autosetup configure; that needs a
# host tclsh once to generate the amalgamation, and cross-compiles with
# nothing more than CC + --host. Readline is off (the Tunix image carries
# none) and the TCL bindings are host-tool machinery, not something to ship.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for webkit
#   $OUT/sqlite-root/usr/lib                  libsqlite3
#   $OUT/sqlite-root/usr/bin                  the sqlite3 shell

PORT_NAME=sqlite
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SQLITE_SOURCE="$ROOT/ports/src/sqlite"

BUILD="$OUT/sqlite-build"
ROOT_DIR="$OUT/sqlite-root"

EXPECTED_SQLITE_VERSION=3.50.4

[[ -f "$SQLITE_SOURCE/configure" ]] || cross_port_fail \
    "missing $SQLITE_SOURCE/configure; run git submodule update --init ports/src/sqlite"

cross_port_require_toolchain
cross_port_require_tools make tclsh "$READELF"

sqlite_version=$(tr -d '[:space:]' < "$SQLITE_SOURCE/VERSION")
[[ "$sqlite_version" == "$EXPECTED_SQLITE_VERSION" ]] || \
    cross_port_fail "expected sqlite $EXPECTED_SQLITE_VERSION, found ${sqlite_version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_export_pkg_config

(
    cd "$BUILD"
    # --soname=legacy: without it the autosetup build ships libsqlite3.so
    # with *no* SONAME, so consumers record the absolute link-time path in
    # their NEEDED entries -- which is how libsoup ended up depending on a
    # path inside the build sysroot.
    CC="$CROSS_CC" CFLAGS="-O2 -fPIC" \
    "$SQLITE_SOURCE/configure" \
        --host="$CROSS_TARGET" \
        --prefix=/usr \
        --soname=legacy \
        --disable-readline --disable-editline --disable-tcl \
        > configure.log
    make -j "$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
)

make -C "$BUILD" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
make -C "$BUILD" install DESTDIR="$ROOT_DIR" > /dev/null

[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/sqlite3.pc" ]] || \
    cross_port_fail "sqlite3.pc was not installed"

library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libsqlite3.so*' -print -quit)
[[ -n "$library" ]] || cross_port_fail "libsqlite3.so was not installed"
cross_port_check_library "$library" "libsqlite3.so.0"
[[ -f "$ROOT_DIR/usr/bin/sqlite3" ]] || cross_port_fail "the sqlite3 shell was not installed"

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 -name '*.a' -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
"$CROSS_STRIP" --strip-all "$ROOT_DIR/usr/bin/sqlite3" 2>/dev/null || true
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'sqlite %s staged at %s (%s)\n' "$sqlite_version" "$ROOT_DIR" "$size"
