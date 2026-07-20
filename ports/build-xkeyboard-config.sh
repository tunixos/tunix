#!/usr/bin/env bash
set -euo pipefail

# Stage the xkeyboard-config keyboard database for Tunix.
#
# This is the data half of libxkbcommon. The library can compile a keymap given
# as text, but Weston -- like everything else -- asks for one by *name*
# (evdev/pc105/us), and that lookup reads the rules, keycodes, types, compat and
# symbols files from $XKB_CONFIG_ROOT. Without them libxkbcommon reports
# "Failed to add any default include path" and the compositor has no keyboard.
#
# Unlike every other port here this one compiles nothing: upstream's
# project() declares no language, so there is no cross build to do and no
# toolchain involved. It is a file install, and meson runs natively.
#
# The path has to match what ports/build-libxkbcommon.sh baked in as
# DFLT_XKB_CONFIG_ROOT, which is the usual /usr/share/X11/xkb.
#
# Output layout:
#   $OUT/xkeyboard-config-root/usr/share/X11/xkb   the database, staged for the image

PORT_NAME=xkeyboard-config
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/ports/out}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

SOURCE="$ROOT/ports/src/xkeyboard-config"
BUILD="$OUT/xkeyboard-config-build"
ROOT_DIR="$OUT/xkeyboard-config-root"

EXPECTED_VERSION=2.48
XKB_CONFIG_ROOT=/usr/share/X11/xkb

fail() {
    echo "build-$PORT_NAME: $*" >&2
    exit 1
}

[[ -f "$SOURCE/meson.build" ]] || fail \
    "missing xkeyboard-config source at $SOURCE; run git submodule update --init --recursive"
for tool in meson ninja; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool was not found"
done

version=$(sed -n "s/^[[:space:]]*version:[[:space:]]*'\([0-9.]*\)'.*/\1/p" \
    "$SOURCE/meson.build" | head -n1)
[[ "$version" == "$EXPECTED_VERSION" ]] || \
    fail "expected xkeyboard-config $EXPECTED_VERSION, found ${version:-unknown}"

rm -rf "$BUILD" "$ROOT_DIR"
mkdir -p "$BUILD/src" "$BUILD/obj" "$ROOT_DIR"

# Work on a copy, because the tree needs a fixup that must not touch ports/src.
tar -C "$SOURCE" --exclude=.git -cf - . | tar -C "$BUILD/src" -xf -

# Materialise the symlinks git could not create.
#
# The database uses symlinks for alias layouts -- symbols/caps points at
# symbols/capslock, and so on for eight files. A Windows checkout with
# core.symlinks=false writes each of those as a *regular file containing the
# target path*. The rules generator then resolves caps:backspace by opening
# symbols/caps, finds one line of text instead of the sections it expects, and
# aborts with "does not resolve to any section".
#
# Replacing the placeholder with a copy of its target fixes it everywhere: the
# generator only reads content, so a copy serves as well as a link. Entries that
# really are symlinks (any normal Linux checkout) are left alone.
if command -v git >/dev/null 2>&1 && [[ -e "$SOURCE/.git" ]]; then
    while read -r link_path; do
        [[ -n "$link_path" ]] || continue
        target_file="$BUILD/src/$link_path"
        [[ -f "$target_file" && ! -L "$target_file" ]] || continue
        target=$(cat "$target_file")
        # Targets are relative to the link's own directory.
        resolved="$(dirname "$target_file")/$target"
        [[ -f "$resolved" ]] || fail "cannot resolve the $link_path link to '$target'"
        cp -f "$resolved" "$target_file"
        echo "build-$PORT_NAME: materialised $link_path -> $target"
    done < <(git -C "$SOURCE" ls-files -s | awk '$1 == "120000" { print $4 }')
fi

# nls off: the translated layout descriptions are only ever shown by graphical
# layout pickers, which Tunix has none of, and they are a large share of the
# installed size.
meson setup "$BUILD/obj" "$BUILD/src" \
    --prefix=/usr \
    -Dnls=false \
    -Dcompat-rules=true \
    -Dxorg-rules-symlinks=false

meson compile -C "$BUILD/obj" -j "$JOBS"
DESTDIR="$ROOT_DIR" meson install -C "$BUILD/obj" --no-rebuild

# Upstream installs the database in a versioned directory and makes
# $XKB_CONFIG_ROOT an *absolute* symlink to it. That is correct for the image,
# where the target is staged alongside, but it makes the obvious check useless
# here: on a build host that has xkeyboard-config installed, the absolute link
# resolves into the *host's* database and every test passes no matter what we
# staged. So verify the real directory, then verify the link separately.
DATA_DIR="$ROOT_DIR/usr/share/xkeyboard-config-${EXPECTED_VERSION%%.*}"
for component in rules keycodes types compat symbols; do
    [[ -d "$DATA_DIR/$component" ]] || \
        fail "the $component database was not staged in $DATA_DIR"
done
# evdev is the ruleset libxkbcommon was configured to default to.
[[ -f "$DATA_DIR/rules/evdev" ]] || \
    fail "the evdev ruleset is missing; keymap-by-name lookups will fail"
[[ -f "$DATA_DIR/symbols/us" ]] || fail "the us symbols file is missing"

# The eight alias symlinks are deliberately *not* installed by upstream -- see
# the note in symbols/meson.build about systems that do not support symlinks --
# so their absence here is correct and matches a distribution install. They are
# still materialised in the build copy above, because the rules *generator*
# reads them at build time to resolve options like caps:backspace.
[[ -f "$DATA_DIR/symbols/capslock" ]] || fail "the capslock symbols file is missing"
# The generated compatibility rules are what those options end up in; if the
# generator had silently produced nothing, this would be empty.
grep -q 'caps:' "$DATA_DIR/rules/evdev" || \
    fail "the evdev rules carry no caps: options; the rules generator misfired"

link_target=$(readlink "$ROOT_DIR$XKB_CONFIG_ROOT" || true)
[[ "$link_target" == "/usr/share/xkeyboard-config-${EXPECTED_VERSION%%.*}" ]] || \
    fail "$XKB_CONFIG_ROOT points at '${link_target:-nothing}', not at the staged database"

# Nothing here is a development artefact except the pkg-config data and the
# man pages, which describe the layouts for humans.
rm -rf "$ROOT_DIR/usr/share/pkgconfig" "$ROOT_DIR/usr/share/man" \
       "$ROOT_DIR/usr/share/locale" "$ROOT_DIR/usr/share/doc"

size=$(du -sh "$ROOT_DIR" | cut -f1)
printf 'xkeyboard-config %s staged at %s (%s)\n' "$version" "$ROOT_DIR" "$size"
