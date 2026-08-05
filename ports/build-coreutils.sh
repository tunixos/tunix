#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/ports/lib/gnu-port.sh"

PORT_NAME=coreutils
PORT_SRC="$ROOT/ports/src/coreutils/coreutils"

# FORCE_UNSAFE_CONFIGURE lets coreutils configure run as root (common in CI).
#
# gl_cv_host_operating_system is what `uname -o` (and the last field of
# `uname -a`) prints: gnulib bakes it in at configure time from the host
# triplet, and this is a native musl build, so x86_64-...-linux-musl would
# otherwise compile in "GNU/Linux". Presetting the cache variable names the
# system the binary actually runs on, in gnulib's own kernel/userland form
# (cf. GNU/kFreeBSD): the GNU userland on the Tunix kernel.
PORT_CONFIGURE_ENV=( FORCE_UNSAFE_CONFIGURE=1 gl_cv_host_operating_system=GNU/Tunix )
# stdbuf needs an LD_PRELOAD shared library, useless in a static image; uptime
# is already provided by the Tunix-native procutil tool in /bin.
PORT_CONFIGURE_ARGS=( --enable-no-install-program=stdbuf,uptime )

coreutils_verify() {
    local bin="$1/usr/bin"
    for b in ls cat cp mv rm mkdir chmod echo test; do
        [[ -x "$bin/$b" ]] || gnu_port_fail "coreutils did not install $b"
    done
    [[ -e "$bin/[" ]] || gnu_port_fail "coreutils did not install the [ test binary"
    # The -o string is a compile-time constant, so the static binary answers the
    # same here as it will on Tunix; catch a lost cache variable at build time.
    local os
    os=$("$bin/uname" -o)
    [[ "$os" == "GNU/Tunix" ]] || \
        gnu_port_fail "uname -o reports '$os', expected GNU/Tunix"
}
PORT_VERIFY=coreutils_verify

gnu_autotools_port
