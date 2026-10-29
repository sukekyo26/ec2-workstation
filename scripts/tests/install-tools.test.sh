#!/usr/bin/env bash
# scripts/install-jv.sh・scripts/install-shfmt.sh (共通の流れは scripts/lib/tools.sh) の取り方と止まり方を、
# 偽の curl・uname で確かめる (ネットワークに出ない)。
# - スクリプトは一時ディレクトリのリポジトリの形に写して走らせ、道具は写しの .tools に置かせる
# - 偽の curl は URL を $FAKE_CURL_LOG に書き、$FAKE_DOWNLOAD (jv は tarball、shfmt はバイナリ) を返す
# - 固定の sha256 は本物のものなので、偽のものは合わない。合うときを見るには、写しの中の本物の値を探して書き換える
#   (表がどのファイルにあるかは決め打ちしない)
#
#   scripts/tests/install-tools.test.sh
set -euo pipefail

scripts_src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/out" "$work/tarball"

# 偽の curl: --help all には --retry-all-errors を含む一覧を返す。取るときは最後の引数を URL として書き残す
cat > "$work/bin/curl" << 'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = --help ]; then
    printf '%s\n' " --retry <num>  Retry request if transient problems occur" " --retry-all-errors  Retry all errors"
    exit 0
fi
out=
args=("$@")
for i in "${!args[@]}"; do
    if [ "${args[$i]}" = -o ]; then
        out=${args[$((i + 1))]}
    fi
done
echo "${args[-1]}" >> "$FAKE_CURL_LOG"
echo "$*" >> "$FAKE_CURL_LOG.args"
cp "$FAKE_DOWNLOAD" "$out"
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
jv_tarball="$work/jv.tar.gz"
tar -czf "$jv_tarball" -C "$work/tarball" jv
printf '#!/bin/sh\necho fake shfmt\n' > "$work/shfmt.bin"
lib="$scripts_src/lib/tools.sh"
tool() {
    bash -c '. "$1"; shift; "$@"' _ "$lib" "$@"
}
fake_sha=$(tool file_sha256 "$jv_tarball")
fake_shfmt_sha=$(tool file_sha256 "$work/shfmt.bin")
version=$(bash -c '. "$1"; echo "$JV_VERSION"' _ "$lib")
shfmt_version=$(bash -c '. "$1"; echo "$SHFMT_VERSION"' _ "$lib")

# sed -i は GNU と macOS で書き方が違うので、一時ファイルに書いて置き換える
edit() {
    sed -E "$1" "$2" > "$2.new"
    mv "$2.new" "$2"
}

# replace_in_copy <repo> <old> <new>: 写しの scripts/ の下で <old> をちょうど 1 つのファイルに見つけて、<new> に替える
replace_in_copy() {
    local files
    # 見つからなければ grep は rc=1 なので、|| true で下の誤りの文に任せる
    files=$(grep -rlF -- "$2" "$1/scripts" || true)
    if [ "$(wc -l <<< "$files")" -ne 1 ] || [ -z "$files" ]; then
        echo "expected '$2' in exactly one file under $1/scripts, found: $files" >&2
        exit 1
    fi
    edit "s/$2/$3/" "$files"
}

# 写しを作る。"ok" なら、jv と shfmt の linux-amd64 の本物の sha256 を偽のものに書き換える
new_repo() {
    local repo="$work/$1"
    mkdir -p "$repo"
    cp -R "$scripts_src" "$repo/scripts"
    if [ "${2:-}" = ok ]; then
        replace_in_copy "$repo" "$(tool tool_sha256 jv linux-amd64)" "$fake_sha"
        replace_in_copy "$repo" "$(tool tool_sha256 shfmt linux-amd64)" "$fake_shfmt_sha"
    fi
}

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# run <name> <repo> <uname -s> <uname -m> [args...]: install-jv.sh (SCRIPT で替えられる) の rc・標準エラー・curl が取りにいった URL を残す。
# 場合の名前を "case: <name>" で出す (作り替えの前と後で、同じ場合を見ていることを比べるため)
run() {
    local name=$1 repo=$2 rc=0
    echo "case: $name"
    export FAKE_UNAME_S=$3 FAKE_UNAME_M=$4 FAKE_CURL_LOG="$work/out/$name.curl"
    shift 4
    : > "$FAKE_CURL_LOG"
    : > "$FAKE_CURL_LOG.args"
    "$work/$repo/scripts/${SCRIPT:-install-jv.sh}" "$@" > /dev/null 2> "$work/out/$name.err" || rc=$?
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

url=https://github.com/santhosh-tekuri/jsonschema/releases/download/$version
shfmt_url=https://github.com/mvdan/sh/releases/download/$shfmt_version
export FAKE_DOWNLOAD=$jv_tarball

# sha256 が合わなければ止まり、jv も一時ディレクトリも残さない
new_repo bad
run bad bad Linux x86_64
expect_rc bad 1
expect_err bad "sha256 mismatch for jv-$version-linux-amd64.tar.gz: got $fake_sha"
expect_curl bad "$url/jv-$version-linux-amd64.tar.gz"
# 一時的な失敗は取り直し、待ち続けない
# 全体の時間では切らない (大きな pwsh が遅い回線で必ず切れる)。止まったことは速さで見る
for flag in "--retry 3" --retry-all-errors --connect-timeout --speed-limit --speed-time; do
    if ! grep -qF -- "$flag" "$work/out/bad.curl.args"; then
        fail "bad: curl is called without $flag: $(cat "$work/out/bad.curl.args")"
    fi
done
if grep -qF -- --max-time "$work/out/bad.curl.args"; then
    fail "bad: curl is called with --max-time: $(cat "$work/out/bad.curl.args")"
fi
if [ -n "$(ls -A "$work/bad/.tools")" ]; then
    fail "bad: .tools is not empty: $(ls -A "$work/bad/.tools")"
fi

# OS・CPU の名前から取りにいく tarball を決める。対応の無いものは取りにいかずに止まる
for c in "Linux aarch64 linux-arm64" "Darwin arm64 darwin-arm64" "Darwin x86_64 darwin-amd64" "Linux amd64 linux-amd64"; do
    read -r s m asset <<< "$c"
    run "arch-$s-$m" bad "$s" "$m"
    expect_curl "arch-$s-$m" "$url/jv-$version-$asset.tar.gz"
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
if [ "$("$work/ok/.tools/jv-$version/jv" 2>&1)" != "fake jv" ]; then
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
expect_curl force "$url/jv-$version-linux-amd64.tar.gz"
run usage ok Linux x86_64 --forse
expect_rc usage 1
expect_err usage "usage:"

# 版を上げると、古い版の jv があっても validate-config.sh は「無い」で止まり、install-jv.sh は新しい版の場所に置く
replace_in_copy "$work/ok" "JV_VERSION=$version" "JV_VERSION=v9.9.9"
echo "case: bump-validate"
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

# shfmt: バイナリそのもの (tar でない) を、_ で区切った名前の URL から取って置く
export FAKE_DOWNLOAD="$work/shfmt.bin"
SCRIPT=install-shfmt.sh run shfmt-bad bad Linux x86_64
expect_rc shfmt-bad 1
expect_err shfmt-bad "sha256 mismatch for shfmt_${shfmt_version}_linux_amd64: got $fake_shfmt_sha"
expect_curl shfmt-bad "$shfmt_url/shfmt_${shfmt_version}_linux_amd64"
SCRIPT=install-shfmt.sh run shfmt-arch-Darwin-arm64 bad Darwin arm64
expect_curl shfmt-arch-Darwin-arm64 "$shfmt_url/shfmt_${shfmt_version}_darwin_arm64"
SCRIPT=install-shfmt.sh run shfmt-riscv64 bad Linux riscv64
expect_rc shfmt-riscv64 1
expect_err shfmt-riscv64 "unsupported CPU riscv64: shfmt $shfmt_version is released for amd64 and arm64"
SCRIPT=install-shfmt.sh run shfmt-ok ok Linux x86_64
expect_rc shfmt-ok 0
if [ "$("$work/ok/.tools/shfmt-$shfmt_version/shfmt" 2>&1)" != "fake shfmt" ]; then
    fail "shfmt-ok: the installed shfmt does not run"
fi

# install_pinned_tool を 1 つのシェルで 2 回呼んでも、一時ディレクトリが残らず、呼び出し元の EXIT の trap は上書きされない。
# 失敗を見落とさないよう、条件 (if・&&・||) では呼ばない (失敗の後片付けは bad・no-member の場合で見る)
echo "case: twice"
new_repo twice
out=$(FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 FAKE_CURL_LOG="$work/out/twice.curl" bash -c '
    set -euo pipefail
    . "$1/scripts/lib/tools.sh"
    trap "echo caller-trap" EXIT
    install_pinned_tool shfmt v1 https://example.invalid/shfmt-v1 "$2" "" 2> /dev/null
    install_pinned_tool shfmt v2 https://example.invalid/shfmt-v2 "$2" "" 2> /dev/null
    echo second-done
' _ "$work/twice" "$fake_shfmt_sha")
if [ "$out" != "$(printf '%s\n' second-done caller-trap)" ]; then
    fail "twice: got '$out'"
fi
if [ -n "$(find "$work/twice/.tools" -maxdepth 1 -name 'tmp.*')" ] || [ ! -x "$work/twice/.tools/shfmt-v1/shfmt" ] || [ ! -x "$work/twice/.tools/shfmt-v2/shfmt" ]; then
    fail "twice: a temporary directory is left, or shfmt is not installed: $(ls -A "$work/twice/.tools")"
fi

# tar の中に名前が無い tarball なら、rc≠0 で、何も置かず、一時ディレクトリも残さない
echo "case: no-member"
mkdir -p "$work/no-member-src"
echo other > "$work/no-member-src/other"
tar -czf "$work/no-member.tar.gz" -C "$work/no-member-src" other
new_repo no-member
rc=0
FAKE_DOWNLOAD="$work/no-member.tar.gz" FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 FAKE_CURL_LOG="$work/out/no-member.curl" bash -c '
    set -euo pipefail
    . "$1/scripts/lib/tools.sh"
    install_pinned_tool jv v0 https://example.invalid/jv-v0.tar.gz "$(file_sha256 "$2")" jv
' _ "$work/no-member" "$work/no-member.tar.gz" 2> "$work/out/no-member.err" || rc=$?
if [ "$rc" = 0 ] || [ -e "$work/no-member/.tools/jv-v0" ] || [ -n "$(find "$work/no-member/.tools" -maxdepth 1 -name 'tmp.*')" ]; then
    fail "no-member: rc=$rc, want rc!=0 and nothing installed: $(ls -A "$work/no-member/.tools")"
fi

# tofu・just・shellcheck・gitleaks: 添付ファイルの名前の形から URL を作る (OS・CPU の 2 通り)。版は tools.sh から読む
export FAKE_DOWNLOAD=$jv_tarball
gh=https://github.com
tv=$(tool tool_version tofu) jt=$(tool tool_version just) sc=$(tool tool_version shellcheck) gl=$(tool tool_version gitleaks)
pw=$(tool tool_version pwsh) psa=$(tool tool_version psscriptanalyzer)
for c in "tofu Linux x86_64 opentofu/opentofu/releases/download/$tv/tofu_${tv#v}_linux_amd64.tar.gz" \
    "tofu Darwin arm64 opentofu/opentofu/releases/download/$tv/tofu_${tv#v}_darwin_arm64.tar.gz" \
    "just Linux x86_64 casey/just/releases/download/$jt/just-$jt-x86_64-unknown-linux-musl.tar.gz" \
    "just Darwin arm64 casey/just/releases/download/$jt/just-$jt-aarch64-apple-darwin.tar.gz" \
    "shellcheck Linux x86_64 koalaman/shellcheck/releases/download/$sc/shellcheck-$sc.linux.x86_64.tar.gz" \
    "shellcheck Darwin arm64 koalaman/shellcheck/releases/download/$sc/shellcheck-$sc.darwin.aarch64.tar.gz" \
    "gitleaks Linux x86_64 gitleaks/gitleaks/releases/download/$gl/gitleaks_${gl#v}_linux_x64.tar.gz" \
    "gitleaks Darwin arm64 gitleaks/gitleaks/releases/download/$gl/gitleaks_${gl#v}_darwin_arm64.tar.gz" \
    "pwsh Linux x86_64 PowerShell/PowerShell/releases/download/$pw/powershell-${pw#v}-linux-x64.tar.gz" \
    "pwsh Darwin arm64 PowerShell/PowerShell/releases/download/$pw/powershell-${pw#v}-osx-arm64.tar.gz"; do
    read -r t s m path <<< "$c"
    SCRIPT="install-$t.sh" run "url-$t-$s-$m" bad "$s" "$m"
    expect_rc "url-$t-$s-$m" 1
    expect_curl "url-$t-$s-$m" "$gh/$path"
    expect_err "url-$t-$s-$m" "sha256 mismatch"
done

# tar の中でディレクトリの下にあるもの (shellcheck-<版>/shellcheck) も取り出して置く
mkdir -p "$work/sc/shellcheck-$sc"
printf '#!/bin/sh\necho fake shellcheck\n' > "$work/sc/shellcheck-$sc/shellcheck"
chmod +x "$work/sc/shellcheck-$sc/shellcheck"
tar -czf "$work/shellcheck.tar.gz" -C "$work/sc" "shellcheck-$sc"
new_repo sc
replace_in_copy "$work/sc" "$(tool tool_sha256 shellcheck linux-amd64)" "$(tool file_sha256 "$work/shellcheck.tar.gz")"
FAKE_DOWNLOAD="$work/shellcheck.tar.gz" SCRIPT=install-shellcheck.sh run shellcheck-ok sc Linux x86_64
expect_rc shellcheck-ok 0
if [ "$("$work/sc/.tools/shellcheck-$sc/shellcheck" 2>&1)" != "fake shellcheck" ]; then
    fail "shellcheck-ok: the installed shellcheck does not run"
fi

# pwsh: tar の中を全部、置き場所のディレクトリにする。取り直し (--force) では前の中身を残さない
mkdir -p "$work/pw"
printf '#!/bin/sh\necho fake pwsh\n' > "$work/pw/pwsh"
echo runtime > "$work/pw/libfake.so"
chmod +x "$work/pw/pwsh"
tar -czf "$work/pwsh.tar.gz" -C "$work/pw" pwsh libfake.so
new_repo pw
replace_in_copy "$work/pw" "$(tool tool_sha256 pwsh linux-amd64)" "$(tool file_sha256 "$work/pwsh.tar.gz")"
FAKE_DOWNLOAD="$work/pwsh.tar.gz" SCRIPT=install-pwsh.sh run pwsh-ok pw Linux x86_64
expect_rc pwsh-ok 0
if [ "$("$work/pw/.tools/pwsh-$pw/pwsh" 2>&1)" != "fake pwsh" ] || [ ! -f "$work/pw/.tools/pwsh-$pw/libfake.so" ]; then
    fail "pwsh-ok: the whole archive is not installed: $(ls -A "$work/pw/.tools/pwsh-$pw" 2>&1)"
fi
touch "$work/pw/.tools/pwsh-$pw/stale"
FAKE_DOWNLOAD="$work/pwsh.tar.gz" SCRIPT=install-pwsh.sh run pwsh-force pw Linux x86_64 --force
expect_rc pwsh-force 0
if [ -e "$work/pw/.tools/pwsh-$pw/stale" ] || [ -n "$(find "$work/pw/.tools" -maxdepth 1 -name 'tmp.*')" ]; then
    fail "pwsh-force: a stale file or a temporary directory is left"
fi

# PSScriptAnalyzer: PowerShell Gallery の .nupkg を確かめて、モジュールの形 (.tools/psmodules/PSScriptAnalyzer/<版>) に展開する
mkdir -p "$work/psa-src"
echo "@{ ModuleVersion = '$psa' }" > "$work/psa-src/PSScriptAnalyzer.psd1"
(cd "$work/psa-src" && python3 -I -m zipfile -c "$work/psa.nupkg" PSScriptAnalyzer.psd1)
SCRIPT=install-psscriptanalyzer.sh run psa-url bad Linux x86_64
expect_curl psa-url "https://www.powershellgallery.com/api/v2/package/PSScriptAnalyzer/$psa"
expect_rc psa-url 1
new_repo psa
replace_in_copy "$work/psa" "$(tool tool_sha256 psscriptanalyzer linux-amd64)" "$(tool file_sha256 "$work/psa.nupkg")"
FAKE_DOWNLOAD="$work/psa.nupkg" SCRIPT=install-psscriptanalyzer.sh run psa-ok psa Linux x86_64
expect_rc psa-ok 0
if [ ! -f "$work/psa/.tools/psmodules/PSScriptAnalyzer/$psa/PSScriptAnalyzer.psd1" ]; then
    fail "psa-ok: the module is not extracted"
fi

# tools_path は全部の道具の置き場所のディレクトリを : でつなぐ
echo "case: tools-path"
got=$(tool tools_path)
for t in jv shfmt tofu just shellcheck gitleaks pwsh; do
    t="$t-$(tool tool_version "$t")"
    if [[ ":$got:" != *"/.tools/$t:"* ]]; then
        fail "tools-path: $t is missing in $got"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
