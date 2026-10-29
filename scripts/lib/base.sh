# shellcheck shell=bash
# scripts/ のどのスクリプトも読む基本の部品 (scripts/lib/tofu-common.sh・scripts/lib/tools.sh がここを読む)。
# set -e の下で読まれるので、関数は `[ ... ] && cmd` の形で終わらせない (条件が偽のとき rc=1 で呼び出し元が止まる)。
# if・&&・|| の条件で呼んだ関数の中では set -e が効かないので、失敗を見落とせない関数は条件で呼ばない

# コマンド置換 ($(...)) の中でも set -e を効かせる (既定の bash では効かず、中の失敗が黙って空の出力になる)
shopt -s inherit_errexit

# shellcheck disable=SC2034 # このファイルを読むスクリプトが使う
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
  echo "==> $*" >&2
}
