#!/usr/bin/env bash
# scripts/format-shell.sh の対象の選び方と shfmt への渡し方を、偽の shfmt で確かめる。
# - スクリプトは一時ディレクトリの git リポジトリ (scripts/・user-data のテンプレート・空白を含む名前の .sh) に写して走らせる
# - 偽の shfmt は写しの .tools/shfmt-<版>/shfmt に置き、受け取った引数を 1 行に 1 つ書き残し、FAKE_SHFMT_RC で rc を返す
# 本物の shfmt が .editorconfig を読むことは、CI の Shell format のジョブで見る
#
#   scripts/tests/format-shell.test.sh
set -euo pipefail

scripts_src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/opentofu/modules/workstation/templates" "$work/out"
cp -R "$scripts_src" "$repo/scripts"
echo 'echo hi' > "$repo/opentofu/modules/workstation/templates/user-data.sh.tftpl"
echo 'echo hi' > "$repo/scripts/with space.sh"
echo 'not a shell script' > "$repo/README.md"
git -C "$repo" init -q
git -C "$repo" add -A

shfmt=$(bash -c '. "$1/scripts/lib/tools.sh"; shfmt_path' _ "$repo")
mkdir -p "$(dirname "$shfmt")"
cat > "$shfmt" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_SHFMT_LOG"
exit "${FAKE_SHFMT_RC:-0}"
FAKE
chmod +x "$shfmt"

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# run <name> [args...]: scripts/ から呼び、rc・標準出力・標準エラー・shfmt の引数を残す
run() {
    local name=$1 rc=0
    shift
    export FAKE_SHFMT_LOG="$work/out/$name.args"
    : > "$FAKE_SHFMT_LOG"
    (cd "$repo/scripts" && ./format-shell.sh "$@") > "$work/out/$name.out" 2> "$work/out/$name.err" || rc=$?
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
    fi
}

# 対象 (--list の一覧) は、どこから呼んでもリポジトリ全体のシェルスクリプトで、絶対パス。シェルスクリプトでないものは入らない
targets=$(cd "$repo/scripts" && ./format-shell.sh --list | tr '\0' '\n')
if grep -qF "$repo/README.md" <<< "$targets"; then
    fail "list: README.md is a target"
fi
if [ "$(grep -c "^$repo/" <<< "$targets")" -ne "$(wc -l <<< "$targets")" ]; then
    fail "list: some targets are not absolute paths under the repository"
fi

run check
expect_rc check 0
if [ "$(cat "$work/out/check.args")" != "$(printf '%s\n' -d "$targets")" ]; then
    fail "check: shfmt got other arguments (- want, + got)"
    diff <(printf '%s\n' -d "$targets") "$work/out/check.args" | sed 's/^/    /' >&2
fi
for f in "$repo/opentofu/modules/workstation/templates/user-data.sh.tftpl" "$repo/scripts/with space.sh" "$repo/scripts/format-shell.sh"; do
    if ! grep -qxF -- "$f" "$work/out/check.args"; then
        fail "check: $f is not passed to shfmt"
    fi
done

FAKE_SHFMT_RC=1 run check-diff --check
expect_rc check-diff 1

run write --write
expect_rc write 0
if [ "$(head -1 "$work/out/write.args")" != -w ]; then
    fail "write: shfmt got $(head -1 "$work/out/write.args"), want -w"
fi

# 書式の引数 (-i 4・--indent=4・--case-indent など) を渡すと、shfmt は .editorconfig を読まない。
# 許すのは -d・-l・-w だけで、ほかの - で始まる引数は全部断る
for name in check write; do
    if grep -E -- '^-' "$work/out/$name.args" | grep -qvxE -- '-(d|l|w)'; then
        fail "$name: an option other than -d, -l, -w is passed to shfmt: $(grep -E -- '^-' "$work/out/$name.args" | tr '\n' ' ')"
    fi
done

# --list は NUL 区切りで対象を出し、shfmt を呼ばない
run list --list
expect_rc list 0
if [ "$(tr '\0' '\n' < "$work/out/list.out")" != "$targets" ]; then
    fail "list: got other files"
fi
if [ "$(tr -cd '\0' < "$work/out/list.out" | wc -c)" -ne "$(wc -l <<< "$targets")" ]; then
    fail "list: the files are not separated by NUL"
fi
if [ -s "$work/out/list.args" ]; then
    fail "list: shfmt was called"
fi

run usage --fix
expect_rc usage 1
expect_err usage "usage:"
run usage-two --check --write
expect_rc usage-two 1

mv "$shfmt" "$shfmt.off"
run no-shfmt
mv "$shfmt.off" "$shfmt"
expect_rc no-shfmt 1
expect_err no-shfmt "Install it with scripts/install-shfmt.sh"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
