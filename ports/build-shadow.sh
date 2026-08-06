#!/usr/bin/env bash
set -euo pipefail

# Build shadow-utils for Tunix: login, su, passwd and the account tools.
#
# This is the userspace half of the kernel's credential work -- the kernel can
# now hold an identity, and these are the programs that decide which one a
# session gets. login and su read /etc/shadow, verify the crypt(3) hash, and
# then setgid/setuid into the account before exec'ing its shell.
#
# The setuid bits matter here more than anywhere else in the image: su, passwd,
# newgrp, chsh and chfn are installed 4755 and are useless without it, so the
# staged root is checked for them rather than trusted.
#
# musl notes: --with-libbsd=no makes shadow use its own readpassphrase(), and
# logind/PAM/SELinux/audit/tcb/nscd/sssd have nothing behind them on Tunix.
# SHA512 crypt is what /etc/shadow uses and musl implements it in libc.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/ports/lib/gnu-port.sh"

PORT_NAME=shadow
PORT_SRC="$ROOT/ports/src/shadow"

EXPECTED_VERSION=4.16.0
version=$(sed -n 's/^AC_INIT(\[shadow\], \[\([^]]*\)\].*/\1/p' "$PORT_SRC/configure.ac")
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    gnu_port_fail "expected shadow $EXPECTED_VERSION, found ${version:-unknown}"

# shadow ships autogen.sh rather than the `bootstrap` gnu-port.sh knows about,
# so generate configure here and let the shared helper take it from there.
if [[ ! -x "$PORT_SRC/configure" ]]; then
    for tool in autoreconf autopoint libtoolize; do
        command -v "$tool" >/dev/null 2>&1 || \
            gnu_port_fail "$tool is required to bootstrap shadow from a git checkout"
    done
    ( cd "$PORT_SRC" && autoreconf -fi ) || gnu_port_fail "autoreconf failed for shadow"
fi

PORT_CONFIGURE_ARGS=(
    --sysconfdir=/etc
    --localstatedir=/var
    --enable-shadowgrp
    --disable-man
    --disable-logind
    --disable-subordinate-ids
    --disable-account-tools-setuid
    --with-su
    --with-sha-crypt
    --without-libbsd
    --without-libpam
    --without-selinux
    --without-audit
    --without-acl
    --without-attr
    --without-skey
    --without-tcb
    --without-btrfs
    --without-nscd
    --without-sssd
    --without-fcaps
)

gnu_autotools_port

# passwd, chage, useradd and the rest live in ubin_PROGRAMS/usbin_PROGRAMS,
# which automake files under install-data rather than install-exec because the
# directories are not one of its standard ones. Stage them explicitly.
ROOT_DIR="$OUT/$PORT_NAME-root"
( cd "$OUT/$PORT_NAME-build/src" && \
    make install-ubinPROGRAMS install-usbinPROGRAMS DESTDIR="$ROOT_DIR" \
        ACLOCAL=true AUTOCONF=true AUTOMAKE=true AUTOHEADER=true AUTOM4TE=true ) \
    || gnu_port_fail "staging the account tools failed"

for tool in "$ROOT_DIR/bin/login" "$ROOT_DIR/bin/su" "$ROOT_DIR/usr/bin/passwd" \
            "$ROOT_DIR/usr/bin/chage" "$ROOT_DIR/usr/sbin/useradd" \
            "$ROOT_DIR/usr/sbin/groupadd" "$ROOT_DIR/usr/sbin/chpasswd"; do
    [[ -x "$tool" ]] || gnu_port_fail "shadow did not install $(basename "$tool")"
done
# su, passwd and newgrp have to be setuid root to work at all. The mode cannot
# be checked -- or even held -- here, because the staging tree is on a drive
# that reports everything as 0777; scripts/rootfs-permissions.conf is what
# stamps the bit onto the image.
echo "shadow account tools staged at $ROOT_DIR"
