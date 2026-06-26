#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SOURCE="$ROOT/ports/src/tinycc"
URL=https://github.com/TinyCC/tinycc.git
BRANCH=mob

fail() {
    echo "init-tcc-submodule: $*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git was not found"
[[ -d "$ROOT/.git" ]] || fail "run this script inside the Tunix git checkout"

if [[ -e "$SOURCE" && ! -d "$SOURCE/.git" && ! -f "$SOURCE/.git" ]]; then
    fail "$SOURCE exists but is not a git checkout"
fi

if [[ ! -e "$SOURCE" ]]; then
    git -C "$ROOT" clone --branch "$BRANCH" "$URL" "$SOURCE"
fi

git -C "$SOURCE" fetch origin "$BRANCH"
git -C "$SOURCE" checkout "$BRANCH"
git -C "$SOURCE" reset --hard "origin/$BRANCH"

git -C "$ROOT" config -f .gitmodules submodule.ports/src/tinycc.path ports/src/tinycc
git -C "$ROOT" config -f .gitmodules submodule.ports/src/tinycc.url "$URL"
git -C "$ROOT" config -f .gitmodules submodule.ports/src/tinycc.branch "$BRANCH"
git -C "$ROOT" add .gitmodules ports/src/tinycc
git -C "$ROOT" submodule absorbgitdirs ports/src/tinycc >/dev/null 2>&1 || true

echo "TinyCC submodule is ready at ports/src/tinycc"
