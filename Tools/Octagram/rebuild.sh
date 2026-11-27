#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
set -eu

tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
data_dir="$tool_dir/../../Shared/RimeData"
output=${1:-"$data_dir/yah-octagram-zh-hans.gram"}
work=$(mktemp -d "${TMPDIR:-/tmp}/yah-octagram.XXXXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

upstream=https://raw.githubusercontent.com/lotem/rime-octagram-data/f8ce3b534733e489a8470a7c2adf5a154e8ea069
darts=https://raw.githubusercontent.com/s-yata/darts-clone/87b71afd6cf784953e3c08f24c64203397f3b724
curl -fsSL "$upstream/zh-hans-t-essay-bgw.gram" -o "$work/upstream.gram"
curl -fsSL "$darts/include/darts.h" -o "$work/darts.h"
(
    cd "$work"
    shasum -a 256 -c <<'DIGESTS'
d3cb2438c1fdcd6a855dd6ca8f5c1060a29273c6b64c2c2c69af67cd71b6aa7e  upstream.gram
acfb9cb7522d4c6a6f6099b981f7f12edb17a9b77fe33b3d38da9c20cd77301a  darts.h
DIGESTS
)
"${CXX:-c++}" -O2 -std=c++17 -I "$work" "$data_dir/licenses/octagram/prune-word-bigrams.cpp" -o "$work/prune"
"$work/prune" "$work/upstream.gram" "$work/yah-octagram-zh-hans.gram"
(
    cd "$work"
    echo '5761d5a7e1972269f534356ed6499e2ad1857a55d2e8576c1f277ee1d800a8f8  yah-octagram-zh-hans.gram' | shasum -a 256 -c
)
install -m 644 "$work/yah-octagram-zh-hans.gram" "$output"
