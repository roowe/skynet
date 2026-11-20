#!/usr/bin/env bash
set -euo pipefail

src="$1"
revision="$2"
out="$3"

if [[ ! -e "$src/.git" ]] || ! git -C "$src" cat-file -e "$revision^{commit}" 2>/dev/null; then
    printf '%s\n' 'Initialize the pinned jemalloc submodule with git submodule update --init.' >&2
    exit 1
fi

version=$(git -C "$src" describe --long --abbrev=40 --match '[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' "$revision" 2>/dev/null) || version="0.0.0-0-g$revision"
git -C "$src" archive "$revision" | tar -xf - -C "$out"
cd "$out"

./autogen.sh --disable-cxx --with-jemalloc-prefix=je_ --enable-prof --with-version="$version"
make lib/libjemalloc_pic.a
