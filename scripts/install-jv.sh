#!/usr/bin/env bash
# workstation-config.json の検証に使う jv (github.com/santhosh-tekuri/jsonschema) を、GitHub のリリースから
# <リポジトリ>/.tools/jv-<版>/jv に取る。sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 要るもの: curl・tar と sha256sum か shasum
#
#   scripts/install-jv.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "unsupported OS $(uname -s): run this on Linux, macOS, WSL, or the CI" ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "unsupported CPU $(uname -m): jv $JV_VERSION is released for amd64 and arm64" ;;
esac

want=$(jv_sha256 "$os-$arch")

dest=$(jv_path)
if [ -x "$dest" ] && [ "${1:-}" != --force ]; then
    log "jv $JV_VERSION is already installed at $dest"
    exit 0
fi

# 一時ディレクトリで取って確かめ、最後に mv で置く。途中で止まっても置き場所に中途半端な jv が残らない
mkdir -p "$REPO_ROOT/.tools"
tmp=$(mktemp -d "$REPO_ROOT/.tools/tmp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

asset="jv-$JV_VERSION-$os-$arch.tar.gz"
log "downloading $asset"
# deploy のたびに GitHub Releases から取るので、一時的な失敗は取り直す。--retry-all-errors は curl 7.71 から
retry=(--retry 3 --retry-delay 2)
# grep -q で途中で読むのをやめると、pipefail の下で curl の SIGPIPE が失敗になるので、全部読ませる
if curl --help all 2> /dev/null | grep -- --retry-all-errors > /dev/null; then
    retry+=(--retry-all-errors)
fi
curl -fsSL "${retry[@]}" --connect-timeout 10 --max-time 120 -o "$tmp/$asset" \
    "https://github.com/santhosh-tekuri/jsonschema/releases/download/$JV_VERSION/$asset"
got=$(file_sha256 "$tmp/$asset")
if [ "$got" != "$want" ]; then
    die "sha256 mismatch for $asset: got $got, want $want"
fi
tar -xzf "$tmp/$asset" -C "$tmp" jv
chmod +x "$tmp/jv"
mkdir -p "$(dirname "$dest")"
mv "$tmp/jv" "$dest"
log "installed jv $JV_VERSION at $dest"
