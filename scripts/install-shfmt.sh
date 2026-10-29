#!/usr/bin/env bash
# シェルスクリプトの書式の検査 (scripts/format-shell.sh) に使う shfmt (github.com/mvdan/sh) を、GitHub のリリースから
# <リポジトリ>/.tools/shfmt-<版>/shfmt に取る。sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl と sha256sum か shasum
#
#   scripts/install-shfmt.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

platform=$(host_platform shfmt "$SHFMT_VERSION")
want=$(shfmt_sha256 "$platform")
# リリースの添付ファイルは tar でなくバイナリそのもので、名前は shfmt_<版>_linux_amd64 の形 (_ で区切る)
install_pinned_tool shfmt "$SHFMT_VERSION" \
    "https://github.com/mvdan/sh/releases/download/$SHFMT_VERSION/shfmt_${SHFMT_VERSION}_${platform/-/_}" \
    "$want" "" "${1:-}"
