#!/usr/bin/env bash
set -euo pipefail

# Cross-build LLVM 22.1.8 for Tunix (musl) -- just enough for mesa's llvmpipe:
# the X86 codegen + JIT wrapped in a single libLLVM.so. Tunix has no GPU, so all
# rendering is on the CPU; llvmpipe JIT-compiles the rasteriser/shader pipeline,
# which is dramatically faster than softpipe's plain-C interpreter.
#
# Why 22.1.8: cross-compiling LLVM needs a *version-matched native* llvm-tblgen
# (it generates architecture-independent C++ from .td, but must match the source
# revision). The host Arch llvm is exactly 22.1.8, so LLVM_TABLEGEN reuses
# /usr/bin/llvm-tblgen and we skip a second full build. mesa 26.2 wants >= 18.
#
# Built in /var/tmp (ext4): the tree is ~150k files and drvfs is an order of
# magnitude too slow. The build dir is kept across runs for incremental rebuilds
# (override with LLVM_BUILD_DIR; wipe by hand when toolchain flags change).
#
# How mesa finds it: meson's llvm dependency runs `llvm-config` on the BUILD
# machine, so a bare musl target binary (won't exec) or its bare target paths
# (/usr/lib -> host) are both wrong. build-mesa.sh uses a host WRAPPER (generated
# here) that runs the target llvm-config under the musl loader -- same syscall
# ABI, like the cross exe_wrapper -- and rewrites /usr -> the graphics sysroot.
#
# Output:
#   $OUT/graphics-sysroot/usr/{include,lib,bin}  headers, libLLVM.so, cmake,
#                                                target llvm-config (for the wrapper)
#   $OUT/llvm-config-wrapper/llvm-config         host wrapper for mesa's meson
#   $OUT/llvm-root/usr/lib/libLLVM.so            the shared lib, for the image

PORT_NAME=llvm
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}

# shellcheck source=ports/lib/cross-port.sh
source "$ROOT/ports/lib/cross-port.sh"

SOURCE="$ROOT/ports/src/llvm-project/llvm"
BUILD=${LLVM_BUILD_DIR:-/var/tmp/tunix-llvm-build}
ROOT_DIR="$OUT/llvm-root"
TOOLCHAIN="$OUT/tunix-llvm-cmake.cmake"
WRAPPER_DIR="$OUT/llvm-config-wrapper"

EXPECTED_VERSION=22.1.8

[[ -f "$SOURCE/CMakeLists.txt" ]] || cross_port_fail \
    "missing LLVM source at $SOURCE; run git submodule update --init"
cross_port_require_toolchain
cross_port_require_tools cmake ninja llvm-tblgen "$READELF"

host_ver=$(llvm-tblgen --version 2>/dev/null | sed -n 's/.*LLVM version \([0-9.]*\).*/\1/p')
[[ "$host_ver" == "$EXPECTED_VERSION" ]] || cross_port_fail \
    "host llvm-tblgen is '${host_ver:-none}', need $EXPECTED_VERSION to match the target build (pacman -S llvm)"

rm -rf "$ROOT_DIR" "$WRAPPER_DIR"
mkdir -p "$ROOT_DIR" "$WRAPPER_DIR" "$BUILD"

# CMake cross toolchain. The emulator = the musl loader, so LLVM's try_run checks
# execute the target probe binaries here (same x86_64 syscall ABI) instead of
# guessing. TRY_COMPILE stays the default EXECUTABLE because of that.
cat > "$TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER "$CROSS_CC")
set(CMAKE_CXX_COMPILER "$CROSS_CXX")
set(CMAKE_AR "$CROSS_AR")
set(CMAKE_RANLIB "$CROSS_DIR/bin/$CROSS_TARGET-ranlib")
set(CMAKE_FIND_ROOT_PATH "$GRAPHICS_SYSROOT/usr")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_CROSSCOMPILING_EMULATOR "$CROSS_LOADER;--library-path;$CROSS_SYSROOT/lib")
EOF

# Configure. X86 target only (llvmpipe targets the host CPU); one libLLVM.so;
# no clang/lld/runtimes/tools/tests; the optional compression/terminfo deps off.
cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DLLVM_TABLEGEN=/usr/bin/llvm-tblgen \
    -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-unknown-linux-musl \
    -DLLVM_HOST_TRIPLE=x86_64-unknown-linux-musl \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -DLLVM_TARGET_ARCH=X86 \
    -DLLVM_BUILD_LLVM_DYLIB=ON \
    -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_ENABLE_RUNTIMES="" \
    -DLLVM_ENABLE_RTTI=OFF \
    -DLLVM_ENABLE_EH=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_ENABLE_THREADS=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DCMAKE_C_FLAGS="-O2" -DCMAKE_CXX_FLAGS="-O2"

if [[ "${LLVM_CONFIGURE_ONLY:-0}" == "1" ]]; then
    printf 'llvm configure OK (%s)\n' "$BUILD"
    exit 0
fi

# Build only the dylib and the target llvm-config -- not the hundreds of tools.
ninja -C "$BUILD" -j "$JOBS" LLVM llvm-config

# Install the pieces we need, by component (only these were built).
for comp in llvm-headers LLVM; do
    DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$BUILD" --component "$comp"
done
# cmake package files help any consumer that prefers cmake over llvm-config.
DESTDIR="$GRAPHICS_SYSROOT" cmake --install "$BUILD" --component cmake-exports 2>/dev/null || true
# llvm-config's *install* rule is excluded by LLVM_BUILD_TOOLS=OFF, but the
# binary itself was built (named explicitly as a ninja target), so copy it in
# directly -- the wrapper runs it under the loader to report target paths.
install -Dm755 "$BUILD/bin/llvm-config" "$GRAPHICS_SYSROOT/usr/bin/llvm-config"

[[ -f "$GRAPHICS_SYSROOT/usr/lib/libLLVM.so" ]] || \
    cross_port_fail "libLLVM.so was not installed into the graphics sysroot"
[[ -x "$GRAPHICS_SYSROOT/usr/bin/llvm-config" ]] || \
    cross_port_fail "the target llvm-config was not installed"

# Host wrapper for mesa's meson. It runs the target llvm-config DIRECTLY, not
# under the loader: invoking the loader makes /proc/self/exe point at the loader,
# and llvm-config derives its prefix from that -- it would then hunt for libLLVM
# in the cross sysroot and fail ("libLLVM-22.so is missing"). Direct execution
# needs the ld-musl shim (below) so the target binary's ELF interpreter resolves;
# then /proc/self/exe is the real binary in the graphics sysroot and every path
# llvm-config prints is already sysroot-absolute -- exactly what the cross mesa
# build wants, so no path rewriting is needed.
ln -sf "$CROSS_LOADER" /lib/ld-musl-x86_64.so.1
cat > "$WRAPPER_DIR/llvm-config" <<EOF
#!/usr/bin/env bash
# The ld-musl shim is host-global and not persistent (a WSL restart drops it),
# so self-heal it here -- without it the target binary's ELF interpreter is
# missing and the kernel reports the binary itself as "No such file or
# directory", which meson reports as "llvm-config found: NO".
[ -e /lib/ld-musl-x86_64.so.1 ] || ln -sf "$CROSS_LOADER" /lib/ld-musl-x86_64.so.1 2>/dev/null || true
exec env LD_LIBRARY_PATH="$CROSS_SYSROOT/lib:$GRAPHICS_SYSROOT/usr/lib" \\
    "$GRAPHICS_SYSROOT/usr/bin/llvm-config" "\$@"
EOF
chmod +x "$WRAPPER_DIR/llvm-config"
wrap_ver=$("$WRAPPER_DIR/llvm-config" --version)
[[ "$wrap_ver" == "$EXPECTED_VERSION" ]] || \
    cross_port_fail "the llvm-config wrapper reports '$wrap_ver', expected $EXPECTED_VERSION"

# The image needs only the shared library (real file + SONAME link if any).
mkdir -p "$ROOT_DIR/usr/lib"
cp -P "$GRAPHICS_SYSROOT/usr/lib/libLLVM.so"* "$ROOT_DIR/usr/lib/" 2>/dev/null || \
    cp "$GRAPHICS_SYSROOT/usr/lib/libLLVM.so" "$ROOT_DIR/usr/lib/"
cross_port_stage_cxx_runtime "$ROOT_DIR/usr/lib"
cross_port_finalize_root "$ROOT_DIR"
cross_port_check_library "$ROOT_DIR/usr/lib/libLLVM.so" "$(${READELF} -d "$ROOT_DIR/usr/lib/libLLVM.so" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')"

size=$(du -sh "$ROOT_DIR/usr/lib/libLLVM.so" | cut -f1)
printf 'llvm %s (X86, libLLVM.so %s) staged at %s\n' "$EXPECTED_VERSION" "$size" "$ROOT_DIR"
