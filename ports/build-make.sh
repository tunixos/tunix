#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/ports/lib/gnu-port.sh"

PORT_NAME=make
PORT_SRC="$ROOT/ports/src/make"

# --without-guile: the default is to probe for guile with pkg-config, which
#   finds the *build host's* copy and links a shared library the static image
#   cannot use. Tunix has no guile, and the GNU Guile extension is optional.
# --disable-load: the 'load' directive dlopen()s shared objects at runtime,
#   which cannot work in a fully static binary.
# --disable-posix-spawn: posix_spawn buys nothing here and fork/exec is the
#   path the kernel actually exercises.
PORT_CONFIGURE_ARGS=(
    --without-guile
    --disable-load
    --disable-posix-spawn
)

# make's bundled lib/fnmatch.c still declares K&R prototypes such as
#   extern char *getenv ();
# Since GCC 14 the default is -std=gnu23, where empty parentheses mean (void)
# rather than "unspecified arguments", so that clashes with musl's real
# getenv(const char *) and the build fails. Compiling this port as C17 restores
# the pre-C23 reading; the source is fine, only the default standard moved.
PORT_EXTRA_CFLAGS="-std=gnu17"

make_verify() {
    local root="$1"
    [[ -x "$root/usr/bin/make" ]] || gnu_port_fail "make binary missing"
    # Static musl binaries run on the Linux build host too, so the built make
    # can vouch for itself before it ever reaches Tunix.
    local version
    version=$("$root/usr/bin/make" --version 2>/dev/null | sed -n '1s/^GNU Make //p')
    [[ -n "$version" ]] || gnu_port_fail "built make did not report a version"

    if command -v readelf >/dev/null 2>&1; then
        if readelf -l "$root/usr/bin/make" | grep -q 'INTERP'; then
            gnu_port_fail "make unexpectedly contains a dynamic interpreter"
        fi
        if readelf -d "$root/usr/bin/make" 2>/dev/null | grep -q 'NEEDED'; then
            gnu_port_fail "make unexpectedly contains dynamic dependencies"
        fi
    fi

    printf 'GNU Make %s static binary is ready.\n' "$version"
}
PORT_VERIFY=make_verify

gnu_autotools_port
