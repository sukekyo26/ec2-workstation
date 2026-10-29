#!/usr/bin/env bash
# just ci の pwsh-check に使う PowerShell 7 (github.com/PowerShell/PowerShell) を、GitHub のリリースから
# <リポジトリ>/.tools/pwsh-<版>/ に取る (tar の中を全部。実行ファイルは .tools/pwsh-<版>/pwsh)。
# sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl・tar と sha256sum か shasum。動かすには ICU (libicu) が要る
#
#   scripts/install-pwsh.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

install_tool pwsh "${1:-}"
