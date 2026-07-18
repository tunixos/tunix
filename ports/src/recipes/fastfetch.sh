#!/usr/bin/env bash
set -euo pipefail

# fastfetch recipe. Not a submodule: fetches a pinned tag from GitHub into
# ports/out, applies ports/src/patches/fastfetch, builds a static musl binary.

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
OUT=${OUT:-$ROOT/ports/out}
SYSROOT="$OUT/sysroot"
MUSL_CC="$SYSROOT/usr/bin/musl-gcc"
PATCH_DIR="$ROOT/ports/src/patches/fastfetch"
SOURCE_WORK="$OUT/fastfetch-source"
BUILD="$OUT/fastfetch-build"
FASTFETCH_ROOT="$OUT/fastfetch-root"
FASTFETCH_BINARY="$OUT/fastfetch"
HOST_AR=${AR:-ar}
HOST_RANLIB=${RANLIB:-ranlib}

FASTFETCH_REPO=${FASTFETCH_REPO:-https://github.com/fastfetch-cli/fastfetch}
FASTFETCH_TAG=${FASTFETCH_TAG:-2.66.0}

fail() {
    echo "fastfetch: $*" >&2
    exit 1
}

[[ -x "$MUSL_CC" ]] || fail "missing Tunix musl toolchain; build Bash first"
for tool in git cmake make "$HOST_AR" "$HOST_RANLIB"; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool was not found"
done

# Shallow single-tag fetch: small, and reproducible without vendoring history.
rm -rf "$SOURCE_WORK" "$BUILD" "$FASTFETCH_ROOT"
mkdir -p "$SOURCE_WORK"
git -c advice.detachedHead=false clone --quiet --depth 1 \
    --branch "$FASTFETCH_TAG" "$FASTFETCH_REPO" "$SOURCE_WORK" \
    || fail "could not fetch $FASTFETCH_REPO at $FASTFETCH_TAG"

source_version=$(sed -n 's/^[[:space:]]*VERSION[[:space:]]\+\([0-9.]\+\).*/\1/p' \
    "$SOURCE_WORK/CMakeLists.txt" | head -n1)
[[ "$source_version" == "$FASTFETCH_TAG" ]] || \
    fail "checkout reports version ${source_version:-unknown}, expected $FASTFETCH_TAG"

# git apply, so a drifted patch fails loudly instead of silently doing nothing.
shopt -s nullglob
patches=("$PATCH_DIR"/*.patch)
shopt -u nullglob
[[ ${#patches[@]} -gt 0 ]] || fail "no patches found in $PATCH_DIR"
for patch in "${patches[@]}"; do
    git -C "$SOURCE_WORK" apply --verbose "$patch" \
        || fail "failed to apply $(basename "$patch")"
done
[[ -f "$SOURCE_WORK/src/logo/ascii/t/tunix.txt" ]] || \
    fail "the Tunix logo patch did not land src/logo/ascii/t/tunix.txt"

NO_AUTO_ATOMIC=""
probe=$(mktemp)
probe_object="$probe.o"
trap 'rm -f "$probe" "$probe_object"' EXIT
printf 'int tunix_probe;\n' > "$probe"
if "$MUSL_CC" -fno-link-libatomic -x c -c "$probe" -o "$probe_object" >/dev/null 2>&1; then
    NO_AUTO_ATOMIC="-fno-link-libatomic"
fi

COMMON_CFLAGS="-Os -fno-stack-protector -fno-pie $NO_AUTO_ATOMIC"
COMMON_LDFLAGS="-static -no-pie $NO_AUTO_ATOMIC"

# musl-gcc is a compiler wrapper, not a sysroot cross setup, so an unrestricted
# pkg-config reports the build HOST's libraries: the feature is enabled, then the
# compile fails because musl-gcc cannot see the host include path. Point
# pkg-config at an empty directory so no host package is ever discovered.
EMPTY_PKGCONFIG="$OUT/fastfetch-empty-pkgconfig"
rm -rf "$EMPTY_PKGCONFIG"
mkdir -p "$EMPTY_PKGCONFIG"

# None of these optional features exist on Tunix. Listed explicitly as well as
# isolated above, because ff_lib_enable falls back to find_package(), which
# ignores pkg-config. BINARY_LINK_TYPE=static: the default dlopen cannot work
# in a static binary.
PKG_CONFIG_PATH="$EMPTY_PKGCONFIG" PKG_CONFIG_LIBDIR="$EMPTY_PKGCONFIG" \
cmake -S "$SOURCE_WORK" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$MUSL_CC" \
    -DCMAKE_AR="$(command -v "$HOST_AR")" \
    -DCMAKE_RANLIB="$(command -v "$HOST_RANLIB")" \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="$COMMON_CFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COMMON_LDFLAGS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=OFF \
    -DBINARY_LINK_TYPE=static \
    -DIS_MUSL=ON \
    -DSET_TWEAK=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_FLASHFETCH=OFF \
    -DENABLE_LTO=OFF \
    -DENABLE_SYSTEM_YYJSON=OFF \
    -DENABLE_ZLIB=OFF \
    -DENABLE_LUA=OFF \
    -DENABLE_QUICKJS=OFF \
    -DENABLE_LIBZFS=OFF \
    -DENABLE_WORDEXP=OFF \
    -DENABLE_THREADS=OFF \
    -DENABLE_CHAFA=OFF \
    -DENABLE_DBUS=OFF \
    -DENABLE_DCONF=OFF \
    -DENABLE_DDCUTIL=OFF \
    -DENABLE_DRM=OFF \
    -DENABLE_EET=OFF \
    -DENABLE_EGL=OFF \
    -DENABLE_ELF=OFF \
    -DENABLE_FREETYPE=OFF \
    -DENABLE_GIO=OFF \
    -DENABLE_GLX=OFF \
    -DENABLE_IMAGEMAGICK6=OFF \
    -DENABLE_IMAGEMAGICK7=OFF \
    -DENABLE_OPENCL=OFF \
    -DENABLE_PULSE=OFF \
    -DENABLE_RPM=OFF \
    -DENABLE_SQLITE3=OFF \
    -DENABLE_VADRM=OFF \
    -DENABLE_VAX11=OFF \
    -DENABLE_VDPAU=OFF \
    -DENABLE_VULKAN=OFF \
    -DENABLE_WAYLAND=OFF \
    -DENABLE_XCB_RANDR=OFF \
    -DENABLE_XRANDR=OFF \
    -DINSTALL_LICENSE=ON
PKG_CONFIG_PATH="$EMPTY_PKGCONFIG" PKG_CONFIG_LIBDIR="$EMPTY_PKGCONFIG" \
    cmake --build "$BUILD" --parallel "$JOBS"

[[ -x "$BUILD/fastfetch" ]] || fail "fastfetch binary was not produced"

mkdir -p "$FASTFETCH_ROOT"
DESTDIR="$FASTFETCH_ROOT" cmake --install "$BUILD"
install -Dm0755 "$BUILD/fastfetch" "$FASTFETCH_ROOT/usr/bin/fastfetch"
cp "$BUILD/fastfetch" "$FASTFETCH_BINARY"
chmod 0755 "$FASTFETCH_BINARY"

if command -v readelf >/dev/null 2>&1; then
    if readelf -l "$FASTFETCH_BINARY" | grep -q 'INTERP'; then
        fail "fastfetch unexpectedly contains a dynamic interpreter"
    fi
    if readelf -d "$FASTFETCH_BINARY" 2>/dev/null | grep -q 'NEEDED'; then
        fail "fastfetch unexpectedly contains dynamic dependencies"
    fi
fi

# Only logo assertion possible off-Tunix: reads the compiled-in table. The
# autocompletion form prints one bare name per line, so -qx cannot be fooled.
# stderr is kept: a wrong flag must not look like a missing logo.
logo_list=$("$FASTFETCH_BINARY" --list-logos autocompletion 2>&1) \
    || fail "could not list the built-in logos: $logo_list"
grep -qx 'Tunix' <<<"$logo_list" \
    || fail "the built fastfetch does not expose the Tunix logo"

printf '%s\n' "fastfetch $FASTFETCH_TAG static binary is ready (Tunix logo built in)."
