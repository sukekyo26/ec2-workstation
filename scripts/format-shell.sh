#!/usr/bin/env bash
# シェルスクリプト (*.sh と user-data の *.sh.tftpl) の書式を、版を固定した shfmt (scripts/install-shfmt.sh で入れる) で
# 確かめる・直す。書式の決まりは .editorconfig にあり、shfmt には書式の引数を渡さない (渡すと .editorconfig を読まない)。
# 対象の一覧はここだけが持つ (just の shellcheck も --list を使う)
#
#   scripts/format-shell.sh [--check]  差分を出し、あれば rc≠0
#   scripts/format-shell.sh --write    直す
#   scripts/format-shell.sh --list     対象を NUL 区切りで出す
set -euo pipefail

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"

case "${1:---check}" in
    --check) mode=-d ;;
    --write) mode=-w ;;
    --list) mode=list ;;
    *) die "usage: $0 [--check | --write | --list]" ;;
esac
if [ $# -gt 1 ]; then
    die "usage: $0 [--check | --write | --list]"
fi

files=()
while IFS= read -r -d '' f; do
    files+=("$REPO_ROOT/$f")
done < <(git -C "$REPO_ROOT" ls-files -z -- '*.sh' '*.sh.tftpl')
# プロセス置換の失敗は set -e に届かないので、$! で終わりを待って確かめる
if ! wait "$!"; then
    die "git ls-files failed in $REPO_ROOT"
fi
if [ "${#files[@]}" -eq 0 ]; then
    die "no shell scripts found in $REPO_ROOT (git ls-files)"
fi

if [ "$mode" = list ]; then
    printf '%s\0' "${files[@]}"
    exit 0
fi

shfmt=$(shfmt_path)
if [ ! -x "$shfmt" ]; then
    die "shfmt $SHFMT_VERSION is not installed at $shfmt. Install it with scripts/install-shfmt.sh"
fi
"$shfmt" "$mode" "${files[@]}"
