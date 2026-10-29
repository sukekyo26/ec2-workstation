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

# GitHub のリリースの添付ファイルの sha256 (版は scripts/lib/tofu-common.sh の JV_VERSION)
case "$os-$arch" in
    linux-amd64) want=36e9ab8481cc8e2cb27c8336decc9abdcbd606b05792ca88d6188e01ec28766b ;;
    linux-arm64) want=a9b06c4d73bf3cbe9b3224aacef5329d96267c27febac1152db1ff1659550122 ;;
    darwin-amd64) want=f41e3541d0ba2b5f628d1a04701db3acefcf6aa1feb5c28e10f446dfc584952d ;;
    darwin-arm64) want=d5962c5a7abe0c82be6b69bbed6bd5c9883462f13e0353ddca9878c46ec6ed6f ;;
esac

dest=$(jv_path)
if [ -x "$dest" ] && [ "${1:-}" != --force ]; then
    log "jv $JV_VERSION is already installed at $dest"
    exit 0
fi

sha256() {
    if command -v sha256sum > /dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum > /dev/null; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        die "install sha256sum or shasum to check the download"
    fi
}

# 一時ディレクトリで取って確かめ、最後に mv で置く。途中で止まっても置き場所に中途半端な jv が残らない
mkdir -p "$REPO_ROOT/.tools"
tmp=$(mktemp -d "$REPO_ROOT/.tools/tmp.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

asset="jv-$JV_VERSION-$os-$arch.tar.gz"
log "downloading $asset"
curl -fsSL -o "$tmp/$asset" "https://github.com/santhosh-tekuri/jsonschema/releases/download/$JV_VERSION/$asset"
got=$(sha256 "$tmp/$asset")
if [ "$got" != "$want" ]; then
    die "sha256 mismatch for $asset: got $got, want $want"
fi
tar -xzf "$tmp/$asset" -C "$tmp" jv
chmod +x "$tmp/jv"
mkdir -p "$(dirname "$dest")"
mv "$tmp/jv" "$dest"
log "installed jv $JV_VERSION at $dest"
