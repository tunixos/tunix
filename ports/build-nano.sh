#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
NANO_SOURCE="$ROOT/ports/src/nano"
OUT=${OUT:-$ROOT/ports/out}
SYSROOT="$OUT/sysroot"
MUSL_CC="$SYSROOT/usr/bin/musl-gcc"
NCURSES_ROOT="$OUT/ncurses-root"
SOURCE_WORK="$OUT/nano-source"
BUILD="$OUT/nano-build"
NANO_BINARY="$OUT/nano"
HOST_AR=${AR:-ar}
HOST_RANLIB=${RANLIB:-ranlib}

fail() {
    echo "build-nano: $*" >&2
    exit 1
}

[[ -d "$NANO_SOURCE/src" ]] || fail "missing GNU nano source; initialize submodules"
[[ -x "$MUSL_CC" ]] || fail "missing Tunix musl toolchain"
[[ -f "$NCURSES_ROOT/usr/lib/libncursesw.a" ]] || fail "ncursesw was not built"
[[ -d "$NCURSES_ROOT/usr/share/terminfo" ]] || fail "Tunix terminfo database was not built"
command -v "$HOST_AR" >/dev/null 2>&1 || fail "ar was not found"
command -v "$HOST_RANLIB" >/dev/null 2>&1 || fail "ranlib was not found"

NO_AUTO_ATOMIC=""
probe=$(mktemp)
trap 'rm -f "$probe" "$probe.o"' EXIT
printf 'int tunix_probe;\n' > "$probe"
if "$MUSL_CC" -fno-link-libatomic -x c -c "$probe" -o "$probe.o" >/dev/null 2>&1; then
    NO_AUTO_ATOMIC="-fno-link-libatomic"
fi

rm -rf "$SOURCE_WORK" "$BUILD"
mkdir -p "$SOURCE_WORK" "$BUILD"
cp -a "$NANO_SOURCE/." "$SOURCE_WORK/"

if [[ ! -x "$SOURCE_WORK/configure" ]]; then
    command -v autoreconf >/dev/null 2>&1 || fail "autoreconf is required for the nano Git checkout"
    (
        cd "$SOURCE_WORK"
        if [[ -x ./autogen.sh ]]; then
            ./autogen.sh || fail "nano autotools bootstrap failed; install autoconf, automake, gettext and texinfo"
        else
            autoreconf -fi || fail "nano autoreconf bootstrap failed"
        fi
    )
fi
[[ -x "$SOURCE_WORK/configure" ]] || fail "nano configure script was not generated"
nano_source_version=$($SOURCE_WORK/configure --version 2>/dev/null | sed -n '1s/.* //p')
[[ "$nano_source_version" == "9.1" ]] || \
    fail "expected GNU nano 9.1 source, found ${nano_source_version:-unknown}"

configure_help=$($SOURCE_WORK/configure --help 2>&1 || true)
configure_args=(
    --prefix=/usr
    --sysconfdir=/etc
)
add_if_supported() {
    local option=$1
    if grep -Fq -- "$option" <<<"$configure_help"; then
        configure_args+=("$option")
    fi
}
add_if_supported --disable-nls
add_if_supported --disable-libmagic

NCURSES_LIBS="-lncursesw"
if [[ -f "$NCURSES_ROOT/usr/lib/libtinfow.a" ]]; then
    NCURSES_LIBS="$NCURSES_LIBS -ltinfow"
fi

(
    cd "$BUILD"
    env \
        CC="$MUSL_CC" \
        AR="$HOST_AR" \
        RANLIB="$HOST_RANLIB" \
        PKG_CONFIG_PATH="$NCURSES_ROOT/usr/lib/pkgconfig" \
        PKG_CONFIG_LIBDIR="$NCURSES_ROOT/usr/lib/pkgconfig" \
        CFLAGS="-Os -fno-stack-protector -fno-pie $NO_AUTO_ATOMIC" \
        CPPFLAGS="-D_GNU_SOURCE -I$NCURSES_ROOT/usr/include -I$NCURSES_ROOT/usr/include/ncursesw" \
        LDFLAGS="-static -no-pie -L$NCURSES_ROOT/usr/lib $NO_AUTO_ATOMIC" \
        LIBS="$NCURSES_LIBS" \
        "$SOURCE_WORK/configure" "${configure_args[@]}"
    make -j"$JOBS"
)

[[ -x "$BUILD/src/nano" ]] || fail "GNU nano binary was not produced"
cp "$BUILD/src/nano" "$NANO_BINARY"
chmod 0755 "$NANO_BINARY"

if command -v readelf >/dev/null 2>&1; then
    if readelf -l "$NANO_BINARY" | grep -q 'INTERP'; then
        fail "nano unexpectedly contains a dynamic interpreter"
    fi
    if readelf -d "$NANO_BINARY" 2>/dev/null | grep -q 'NEEDED'; then
        fail "nano unexpectedly contains dynamic dependencies"
    fi
fi

nano_version=$(TERM=tunix-256color \
TERMINFO="$NCURSES_ROOT/usr/share/terminfo" \
    "$NANO_BINARY" --version 2>&1 | sed -n '1s/.* //p')
[[ "$nano_version" == "9.1" ]] || \
    fail "built nano reported version ${nano_version:-unknown}, expected 9.1"

printf '%s\n' 'GNU nano 9.1 static binary is ready.'
