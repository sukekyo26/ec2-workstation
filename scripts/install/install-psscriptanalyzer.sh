#!/usr/bin/env bash
# just ci の pwsh-check (PowerShell のスクリプトの PSScriptAnalyzer) に使うモジュールを、PowerShell Gallery から取り、
# <リポジトリ>/.tools/psmodules/PSScriptAnalyzer/<版> に置く (PSModulePath に scripts/lib/tools.sh の psmodules_path を足して使う)。
# sha256 が合わなければ置かずに止まる。既にあれば何もしない (--force で取り直す)。
# 版と sha256 は scripts/lib/tools.sh にある。要るもの: curl・unzip と sha256sum か shasum
#
#   scripts/install/install-psscriptanalyzer.sh [--force]
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/../lib/tools.sh"

case "${1:-}" in
    '' | --force) ;;
    *) die "usage: $0 [--force]" ;;
esac

# .nupkg (zip) を確かめて置き、モジュールの形に展開する
install_tool psscriptanalyzer "${1:-}"
nupkg=$(tool_path psscriptanalyzer "$PSSCRIPTANALYZER_VERSION")
module_dir="$(psmodules_path)/PSScriptAnalyzer/$PSSCRIPTANALYZER_VERSION"
if [ -f "$module_dir/PSScriptAnalyzer.psd1" ] && [ "${1:-}" != --force ]; then
    exit 0
fi
rm -rf "$module_dir.tmp"
mkdir -p "${module_dir%/*}" || die "could not create ${module_dir%/*}"
unzip -q "$nupkg" -d "$module_dir.tmp" || die "could not unzip $nupkg"
rm -rf "$module_dir"
mv "$module_dir.tmp" "$module_dir"
log "installed the PSScriptAnalyzer module $PSSCRIPTANALYZER_VERSION in $module_dir"
