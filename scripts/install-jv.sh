#!/usr/bin/env bash
# workstation-config.json の検証に使う jv (github.com/santhosh-tekuri/jsonschema) を、GitHub のリリースから
# <リポジトリ>/.tools/jv-<版>/jv に取る。sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl・tar と sha256sum か shasum
#
#   scripts/install-jv.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

install_tool jv "${1:-}"
