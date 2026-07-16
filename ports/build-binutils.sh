#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
MUSL_SOURCE="$ROOT/ports/src/musl"
BINUTILS_SOURCE="$ROOT/ports/src/binutils"
OUT=${OUT:-$ROOT/ports/out}
SYSROOT="$OUT/sysroot"
MUSL_BUILD="$OUT/musl-build"
BINUTILS_BUILD="$OUT/binutils-build"
BINUTILS_ROOT="$OUT/binutils-root"
MUSL_CC="$SYSROOT/usr/bin/musl-gcc"
TOOLCHAIN_STAMP="$SYSROOT/.tunix-musl-toolchain-v4"
HOST_CC=${CC:-gcc}
HOST_AR=${AR:-ar}
HOST_RANLIB=${RANLIB:-ranlib}

# Same architecture and syscall ABI as Linux x86_64, just musl instead of
# glibc, so the produced as/ld/ar run natively on Tunix without any real
# cross-architecture code generation.
TARGET_TRIPLE="x86_64-linux-musl"

fail() {
    echo "build-binutils: $*" >&2
    exit 1
}

[[ -x "$MUSL_SOURCE/configure" ]] || fail "missing musl source; initialize submodules"
[[ -x "$BINUTILS_SOURCE/configure" ]] || fail "missing binutils source; run git submodule update --init --recursive"
for tool in make bison flex makeinfo; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool was not found (required to build binutils from a git checkout)"
done
command -v "$HOST_CC" >/dev/null 2>&1 || fail "$HOST_CC was not found"
command -v "$HOST_AR" >/dev/null 2>&1 || fail "$HOST_AR was not found"
command -v "$HOST_RANLIB" >/dev/null 2>&1 || fail "$HOST_RANLIB was not found"

NO_AUTO_ATOMIC=""
probe=$(mktemp)
trap 'rm -f "$probe" "$probe.bin"' EXIT
printf 'int main(void) { return 0; }\n' > "$probe"
if "$HOST_CC" -fno-link-libatomic -x c "$probe" -o "$probe.bin" >/dev/null 2>&1; then
    NO_AUTO_ATOMIC="-fno-link-libatomic"
fi
COMMON_CFLAGS="-O2 -fno-stack-protector -fno-pie $NO_AUTO_ATOMIC"
COMMON_LDFLAGS="-static -no-pie $NO_AUTO_ATOMIC"

if [[ ! -x "$MUSL_CC" || ! -f "$TOOLCHAIN_STAMP" ]]; then
    rm -rf "$MUSL_BUILD" "$SYSROOT"
    mkdir -p "$MUSL_BUILD" "$SYSROOT"
    (
        cd "$MUSL_BUILD"
        env CC="$HOST_CC" AR="$HOST_AR" RANLIB="$HOST_RANLIB" \
            CFLAGS="$COMMON_CFLAGS" LDFLAGS="$NO_AUTO_ATOMIC" \
            "$MUSL_SOURCE/configure" --prefix="$SYSROOT/usr" --disable-shared
        make -j"$JOBS"
        make install
    )
    : > "$TOOLCHAIN_STAMP"
fi

BUILD_TRIPLE=$("$BINUTILS_SOURCE/config.guess")

rm -rf "$BINUTILS_BUILD" "$BINUTILS_ROOT"
mkdir -p "$BINUTILS_BUILD" "$BINUTILS_ROOT"

# Because --build != --host below, every subdirectory's autoconf/libtool
# machinery looks for cross tools named "$TARGET_TRIPLE-<tool>" on PATH
# (plain AR=/RANLIB= env vars are not honored for this probe). ar/ranlib/nm
# operate on ELF x86_64 object files independent of libc, so the host's own
# copies work unmodified; only the compiler actually needs to be the static
# musl one.
TOOL_PREFIX_DIR="$BINUTILS_BUILD/tool-prefix-bin"
mkdir -p "$TOOL_PREFIX_DIR"
ln -sf "$MUSL_CC" "$TOOL_PREFIX_DIR/$TARGET_TRIPLE-gcc"
ln -sf "$(command -v "$HOST_AR")" "$TOOL_PREFIX_DIR/$TARGET_TRIPLE-ar"
ln -sf "$(command -v "$HOST_RANLIB")" "$TOOL_PREFIX_DIR/$TARGET_TRIPLE-ranlib"
for tool in nm objdump strip objcopy readelf; do
    host_tool=$(command -v "$tool" 2>/dev/null || true)
    [[ -n "$host_tool" ]] && ln -sf "$host_tool" "$TOOL_PREFIX_DIR/$TARGET_TRIPLE-$tool"
done
export PATH="$TOOL_PREFIX_DIR:$PATH"

# --host names the machine the produced as/ld/ar/etc. run on (Tunix, via the
# static musl CC below); --target names what they assemble/link for, which is
# the same machine since this is not a cross-architecture toolchain. Passing
# CC explicitly is what lets a --build != --host configure use the musl-gcc
# wrapper instead of hunting for a "x86_64-linux-musl-gcc" on PATH.
configure_args=(
    --build="$BUILD_TRIPLE"
    --host="$TARGET_TRIPLE"
    --target="$TARGET_TRIPLE"
    --prefix=/usr
    --disable-nls
    --disable-werror
    --disable-shared
    --enable-static
    --disable-gdb
    --disable-gdbserver
    --disable-gdbsupport
    --disable-sim
    --disable-gprof
    --disable-gold
    --disable-libdecnumber
    --disable-readline
    --disable-plugins
    --without-zstd
    --without-zlib
)

(
    cd "$BINUTILS_BUILD"
    env CC="$MUSL_CC" AR_FOR_BUILD="$HOST_AR" RANLIB_FOR_BUILD="$HOST_RANLIB" \
        CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
        "$BINUTILS_SOURCE/configure" "${configure_args[@]}"
    make -j"$JOBS" all-binutils all-gas all-ld
    make install-strip-binutils install-strip-gas install-strip-ld DESTDIR="$BINUTILS_BUILD/install"
)

mkdir -p "$BINUTILS_ROOT/usr/bin"
for tool in as ld ar nm ranlib objcopy objdump readelf size strings strip addr2line; do
    src="$BINUTILS_BUILD/install/usr/bin/$tool"
    [[ -f "$src" ]] || continue
    cp "$src" "$BINUTILS_ROOT/usr/bin/$tool"
    chmod 0755 "$BINUTILS_ROOT/usr/bin/$tool"
done

[[ -x "$BINUTILS_ROOT/usr/bin/as" ]] || fail "staged assembler is missing"
[[ -x "$BINUTILS_ROOT/usr/bin/ld" ]] || fail "staged linker is missing"
[[ -x "$BINUTILS_ROOT/usr/bin/ar" ]] || fail "staged archiver is missing"

echo "Tunix binutils root assembled at $BINUTILS_ROOT"
