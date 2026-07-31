#!/usr/bin/env bash
set -euo pipefail

# Build libtasn1 for Tunix. WebKit requires it unconditionally: the ASN.1
# parsing behind WebCrypto key formats and certificate handling.
#
# The git tree is gnulib-bootstrapped: the first build runs ./bootstrap,
# which clones gnulib (cached under /var/tmp so it happens once) and
# generates configure. That step, like autogen elsewhere, writes generated
# files into the source tree; the cross configure itself runs out of tree.
#
# Output layout:
#   $OUT/graphics-sysroot/usr/{include,lib}   headers + .pc for webkit
#   $OUT/libtasn1-root/usr/lib                libtasn1

PORT_NAME=libtasn1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

TASN1_SOURCE="$ROOT/ports/src/libtasn1"

BUILD=${TASN1_BUILD_DIR:-/var/tmp/tunix-libtasn1-build}
ROOT_DIR="$OUT/libtasn1-root"
GNULIB_CACHE=${GNULIB_CACHE:-/var/tmp/tunix-gnulib}

[[ -f "$TASN1_SOURCE/configure.ac" ]] || cross_port_fail \
    "missing $TASN1_SOURCE/configure.ac; run git submodule update --init ports/src/libtasn1"

cross_port_require_toolchain
cross_port_require_tools make autoreconf bison git "$READELF"

# The build *runs* the cross-compiled asn1Parser to generate the test
# fixtures' _asn1_tab.h headers. Tunix binaries execute on the build host --
# same syscall ABI -- once the musl loader path resolves; this is the
# autotools equivalent of the meson cross file's exe_wrapper.
if [[ ! -e /lib/ld-musl-x86_64.so.1 ]]; then
    ln -s "$CROSS_LOADER" /lib/ld-musl-x86_64.so.1 || cross_port_fail \
        "cannot install the musl loader symlink the exe checks need"
fi

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

cross_port_export_pkg_config

if [[ ! -x "$TASN1_SOURCE/configure" ]]; then
    [[ -d "$GNULIB_CACHE/.git" ]] || \
        git clone --depth 200 https://git.savannah.gnu.org/git/gnulib.git "$GNULIB_CACHE" \
            > "$BUILD/gnulib-clone.log" 2>&1 || \
        git clone --depth 200 https://github.com/coreutils/gnulib.git "$GNULIB_CACHE" \
            > "$BUILD/gnulib-clone.log" 2>&1
    (cd "$TASN1_SOURCE" && GNULIB_REFDIR="$GNULIB_CACHE" ./bootstrap --skip-po \
        > "$BUILD/bootstrap.log" 2>&1) || { tail -30 "$BUILD/bootstrap.log"; exit 1; }
fi

(
    cd "$BUILD"
    CC="$CROSS_CC" CFLAGS="-O2 -fPIC" \
    "$TASN1_SOURCE/configure" \
        --host="$CROSS_TARGET" \
        --prefix=/usr \
        --enable-shared --disable-static \
        --disable-doc --disable-gtk-doc --disable-valgrind-tests \
        > configure.log
    make -j "$JOBS" > build.log 2>&1 || { tail -50 build.log; exit 1; }
)
make -C "$BUILD" install DESTDIR="$GRAPHICS_SYSROOT" > /dev/null
make -C "$BUILD" install DESTDIR="$ROOT_DIR" > /dev/null
rm -f "$GRAPHICS_SYSROOT/usr/lib/libtasn1.la"
[[ -f "$GRAPHICS_SYSROOT/usr/lib/pkgconfig/libtasn1.pc" ]] || \
    cross_port_fail "libtasn1.pc was not installed"

library=$(find "$ROOT_DIR/usr/lib" -maxdepth 1 -type f -name 'libtasn1.so.*' -print -quit)
[[ -n "$library" ]] || cross_port_fail "libtasn1 was not installed"
soname=$("$READELF" -d "$library" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')
cross_port_check_library "$library" "$soname"

rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/pkgconfig" "$ROOT_DIR/usr/bin" \
       "$ROOT_DIR/usr/share"
find "$ROOT_DIR/usr/lib" -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -delete
find "$ROOT_DIR/usr/lib" -maxdepth 1 -type l -name '*.so' -delete

cross_port_finalize_root "$ROOT_DIR"
cross_port_check_runtime_closure "$ROOT_DIR" "$OUT/musl-shared-root"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'libtasn1 staged at %s (%s)\n' "$ROOT_DIR" "$size"
