#!/usr/bin/env bash
# CodePipeline の CodeBuild で just ci を走らせるための just (github.com/casey/just) を、GitHub のリリースから
# <リポジトリ>/.tools/just-<版>/just に取る。sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl・tar と sha256sum か shasum
#
#   scripts/install/install-just.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/../lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

install_tool just "${1:-}"
