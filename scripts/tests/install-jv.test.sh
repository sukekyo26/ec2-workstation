#!/usr/bin/env bash
# scripts/install-jv.sh の取り方と止まり方を、偽の curl・uname で確かめる (ネットワークに出ない)。
# - スクリプトは一時ディレクトリのリポジトリの形に写して走らせ、jv は写しの .tools に置かせる
# - 偽の curl は URL を $FAKE_CURL_LOG に書き、偽の tarball ($FAKE_TARBALL) を返す
# - 固定の sha256 は本物の tarball のものなので、偽の tarball は合わない。合うときを見るには、写しの sha256 を書き換える
#
#   scripts/tests/install-jv.test.sh
set -euo pipefail

scripts_src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/out" "$work/tarball"

cat > "$work/bin/curl" << 'FAKE'
#!/usr/bin/env bash
set -euo pipefail
out=
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2 && shift ;;
        -*) ;;
        *) echo "$1" >> "$FAKE_CURL_LOG" ;;
    esac
    shift
done
cp "$FAKE_TARBALL" "$out"
FAKE
cat > "$work/bin/uname" << 'FAKE'
#!/usr/bin/env bash
case "$1" in
    -s) echo "$FAKE_UNAME_S" ;;
    -m) echo "$FAKE_UNAME_M" ;;
esac
FAKE
chmod +x "$work/bin/curl" "$work/bin/uname"
export PATH="$work/bin:$PATH"

printf '#!/bin/sh\necho fake jv\n' > "$work/tarball/jv"
chmod +x "$work/tarball/jv"
export FAKE_TARBALL="$work/jv.tar.gz"
tar -czf "$FAKE_TARBALL" -C "$work/tarball" jv
fake_sha=$(sha256sum "$FAKE_TARBALL" | cut -d' ' -f1)

# 写しを作る。"ok" なら linux-amd64 の sha256 を偽の tarball のものに書き換える
new_repo() {
    local repo="$work/$1"
    mkdir -p "$repo"
    cp -R "$scripts_src" "$repo/scripts"
    if [ "${2:-}" = ok ]; then
        sed -i -E "s/^( *linux-amd64\) want=)[0-9a-f]+/\1$fake_sha/" "$repo/scripts/install-jv.sh"
        grep -qF "$fake_sha" "$repo/scripts/install-jv.sh"
    fi
}

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# run <name> <repo> <uname -s> <uname -m> [args...]: rc・標準エラー・curl が取りにいった URL を残す
run() {
    local name=$1 repo=$2 rc=0
    export FAKE_UNAME_S=$3 FAKE_UNAME_M=$4 FAKE_CURL_LOG="$work/out/$name.curl"
    shift 4
    : > "$FAKE_CURL_LOG"
    "$work/$repo/scripts/install-jv.sh" "$@" > /dev/null 2> "$work/out/$name.err" || rc=$?
    echo "$rc" > "$work/out/$name.rc"
}

expect_rc() {
    local got
    got=$(cat "$work/out/$1.rc")
    if [ "$got" != "$2" ]; then
        fail "$1: exit code $got, want $2"
        sed 's/^/    /' "$work/out/$1.err" >&2
    fi
}

expect_err() {
    if ! grep -qF -- "$2" "$work/out/$1.err"; then
        fail "$1: stderr does not contain: $2"
        sed 's/^/    /' "$work/out/$1.err" >&2
    fi
}

# 空の期待は「1 度も取りにいかない」
expect_curl() {
    if [ "$(cat "$work/out/$1.curl")" != "$2" ]; then
        fail "$1: downloaded '$(cat "$work/out/$1.curl")', want '$2'"
    fi
}

url=https://github.com/santhosh-tekuri/jsonschema/releases/download/v6.0.3

# sha256 が合わなければ止まり、jv も一時ディレクトリも残さない
new_repo bad
run bad bad Linux x86_64
expect_rc bad 1
expect_err bad "sha256 mismatch for jv-v6.0.3-linux-amd64.tar.gz: got $fake_sha"
expect_curl bad "$url/jv-v6.0.3-linux-amd64.tar.gz"
if [ -n "$(ls -A "$work/bad/.tools")" ]; then
    fail "bad: .tools is not empty: $(ls -A "$work/bad/.tools")"
fi

# OS・CPU の名前から取りにいく tarball を決める。対応の無いものは取りにいかずに止まる
for c in "Linux aarch64 linux-arm64" "Darwin arm64 darwin-arm64" "Darwin x86_64 darwin-amd64" "Linux amd64 linux-amd64"; do
    read -r s m asset <<< "$c"
    run "arch-$s-$m" bad "$s" "$m"
    expect_curl "arch-$s-$m" "$url/jv-v6.0.3-$asset.tar.gz"
done
run arch-riscv64 bad Linux riscv64
expect_rc arch-riscv64 1
expect_err arch-riscv64 "unsupported CPU riscv64"
expect_curl arch-riscv64 ""
run os-mingw bad MINGW64_NT-10.0 x86_64
expect_rc os-mingw 1
expect_err os-mingw "unsupported OS MINGW64_NT-10.0"
expect_curl os-mingw ""

# sha256 が合えば置き、実行できる。既にあれば取りにいかない。--force なら取り直す
new_repo ok ok
run ok ok Linux x86_64
expect_rc ok 0
if [ "$("$work/ok/.tools/jv-v6.0.3/jv" 2>&1)" != "fake jv" ]; then
    fail "ok: the installed jv does not run"
fi
if [ -n "$(find "$work/ok/.tools" -maxdepth 1 -name 'tmp.*')" ]; then
    fail "ok: a temporary directory is left in .tools"
fi
run again ok Linux x86_64
expect_rc again 0
expect_curl again ""
run force ok Linux x86_64 --force
expect_rc force 0
expect_curl force "$url/jv-v6.0.3-linux-amd64.tar.gz"
run usage ok Linux x86_64 --forse
expect_rc usage 1
expect_err usage "usage:"

# 版を上げると、古い版の jv があっても validate-config.sh は「無い」で止まり、install-jv.sh は新しい版の場所に置く
sed -i 's/^JV_VERSION=.*/JV_VERSION=v9.9.9/' "$work/ok/scripts/lib/tofu-common.sh"
rc=0
"$work/ok/scripts/validate-config.sh" 2> "$work/out/bump-validate.err" || rc=$?
if [ "$rc" != 1 ] || ! grep -qF "jv v9.9.9 is not installed" "$work/out/bump-validate.err"; then
    fail "bump: validate-config.sh did not stop for the missing jv v9.9.9 (rc=$rc)"
fi
run bump ok Linux x86_64
expect_rc bump 0
expect_curl bump "https://github.com/santhosh-tekuri/jsonschema/releases/download/v9.9.9/jv-v9.9.9-linux-amd64.tar.gz"
if [ ! -x "$work/ok/.tools/jv-v9.9.9/jv" ]; then
    fail "bump: jv v9.9.9 is not installed"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
