#!/usr/bin/env bash
# シェルスクリプトの書式の検査 (scripts/format-shell.sh) に使う shfmt (github.com/mvdan/sh) を、GitHub のリリースから
# <リポジトリ>/.tools/shfmt-<版>/shfmt に取る。sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl と sha256sum か shasum
#
#   scripts/install/install-shfmt.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/../lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

install_tool shfmt "${1:-}"
