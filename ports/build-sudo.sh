#!/usr/bin/env bash
set -euo pipefail

# Build sudo for Tunix.
#
# sudo is the reason the kernel had to honour the set-user-ID bit: the binary is
# installed 4755, so it starts as root whoever runs it, checks the caller
# against /etc/sudoers, and only then keeps the privilege it was handed.
#
# The build is static like the rest of the musl userland, which for sudo means
# the sudoers policy is linked into the binary instead of being dlopen'd --
# there is no libdl to open it with. Everything behind a facility Tunix does not
# have is switched off: PAM, SSSD, LDAP, OpenSSL, zlib and the log server.
#
# sudo writes its own Makefiles rather than using automake, so it has no
# install-exec target and cannot go through gnu_autotools_port; the toolchain
# setup is shared, the configure/make/install is not.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/ports/lib/gnu-port.sh"

PORT_NAME=sudo
PORT_SRC="$ROOT/ports/src/sudo"
BUILD="$OUT/sudo-build"
ROOT_DIR="$OUT/sudo-root"

EXPECTED_VERSION=1.9.17p2
version=$(sed -n 's/^AC_INIT(\[sudo\], \[\([^]]*\)\].*/\1/p' "$PORT_SRC/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    gnu_port_fail "expected sudo $EXPECTED_VERSION, found ${version:-unknown}"

gnu_port_detect_flags
gnu_port_ensure_toolchain

[[ -x "$PORT_SRC/configure" ]] || gnu_port_fail "sudo ships configure; none found in $PORT_SRC"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD" "$ROOT_DIR"

(
    cd "$BUILD"
    export CC="$MUSL_CC"
    export CFLAGS="$PORT_CFLAGS"
    export LDFLAGS="$COMMON_LDFLAGS"
    "$PORT_SRC/configure" \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --with-rundir=/run/sudo \
        --with-vardir=/var/lib/sudo \
        --disable-shared \
        --enable-static-sudoers \
        --disable-shared-libutil \
        --disable-hardening \
        --disable-pie \
        --disable-log-server \
        --disable-log-client \
        --disable-nls \
        --without-pam \
        --without-sssd \
        --without-ldap \
        --without-selinux \
        --without-apparmor \
        --without-interfaces \
        --disable-openssl \
        --disable-zlib \
        --with-sudoers-mode=0440 \
        --with-editor=/usr/bin/nano \
        --with-env-editor \
        --with-passprompt="[sudo] password for %p: "
    make -j"$JOBS"
    # install-binaries rather than install: the latter drags in the man pages,
    # the sample sudoers and a chown of the timestamp directory, none of which
    # belong in a staging tree.
    make -C src install-binaries DESTDIR="$ROOT_DIR"
    make -C plugins/sudoers install-binaries DESTDIR="$ROOT_DIR"
)

gnu_port_prune_root "$ROOT_DIR"
rm -rf "$ROOT_DIR/usr/include" "$ROOT_DIR/usr/lib/sudo/lib"* 2>/dev/null || true

for tool in "$ROOT_DIR/usr/bin/sudo" "$ROOT_DIR/usr/bin/sudoedit" \
            "$ROOT_DIR/usr/bin/sudoreplay" "$ROOT_DIR/usr/sbin/visudo"; do
    [[ -e "$tool" ]] || gnu_port_fail "sudo did not install $(basename "$tool")"
done
# A loadable policy plugin would be dlopen'd at run time and there is nothing to
# open it with, so sudoers has to be inside the binary.
if [[ -e "$ROOT_DIR/usr/libexec/sudo/sudoers.so" ]]; then
    gnu_port_fail "sudoers was built as a loadable plugin; --enable-static-sudoers did not take"
fi
echo "sudo staged at $ROOT_DIR"
