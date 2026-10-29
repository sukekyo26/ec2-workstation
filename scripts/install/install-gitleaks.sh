#!/usr/bin/env bash
# just ci の gitleaks-scan に使う gitleaks (github.com/gitleaks/gitleaks) を、GitHub のリリースから
# <リポジトリ>/.tools/gitleaks-<版>/gitleaks に取る。sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl・tar と sha256sum か shasum
#
#   scripts/install/install-gitleaks.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/../lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

install_tool gitleaks "${1:-}"
