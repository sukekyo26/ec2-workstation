#!/usr/bin/env bash
# scripts/client/setup-remote-ssh.sh を、偽の aws と偽の session-manager-plugin で確かめる。
# - 接続用のスクリプトはホストごと (~/.ssh/ec2-workstation-proxy-<ホスト>.sh)。別のホストの setup で、ほかのホストのスクリプトと
#   config の節は変わらず、前の版が置いた共有の ~/.ssh/start-ec2-and-wait.sh も残る
# - ホスト名は小文字にし、合わない名前は聞き直す
# HOME は一時ディレクトリ。入力 (Name タグ・ホスト名・リージョン) は stdin で渡す
#
#   scripts/tests/setup-remote-ssh.test.sh
set -euo pipefail

scripts_dir=$(cd "$(dirname "$0")/../client" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home/.ssh"

cat > "$work/bin/aws" << 'FAKE'
#!/usr/bin/env bash
if [ -n "${FAKE_ARGS_LOG:-}" ]; then
    echo "$*" >> "$FAKE_ARGS_LOG"
fi
case "$*" in
    --version)
        if [ "${FAKE_VERSION_FAIL:-}" = 1 ]; then
            echo "fake aws: version stdout"
            echo "" >&2
            echo "fake aws: version failed" >&2
            exit 3
        elif [ "${FAKE_VERSION_STDERR:-}" = 1 ]; then
            echo "aws-cli/1.0.0 fake" >&2
        elif [ "${FAKE_VERSION_EMPTY:-}" = 1 ]; then
            :
        else
            echo "aws-cli/2.0.0 fake"
        fi
        ;;
    "ec2 describe-instances --region "*) echo i-0123456789abcdef0 ;;
    "ec2 describe-instances --instance-ids "*LoginUser*) echo ec2-user ;;
    "ec2 describe-instances --instance-ids "*KeyName*) echo fake-key ;;
    "ec2 describe-key-pairs "*) echo key-0123456789abcdef0 ;;
    "ssm get-parameter "*) echo "FAKE PRIVATE KEY" ;;
    *)
        echo "fake aws: unexpected call: $*" >&2
        exit 2
        ;;
esac
FAKE
cat > "$work/bin/session-manager-plugin" << 'FAKE'
#!/usr/bin/env bash
if [ "${FAKE_PLUGIN_FAIL:-}" = 1 ]; then
    echo "fake plugin: version stdout"
    echo "" >&2
    echo "fake plugin: broken" >&2
    exit 4
fi
echo 1.2.3
FAKE
chmod +x "$work/bin/aws" "$work/bin/session-manager-plugin"

ssh_dir="$work/home/.ssh"
failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# setup <名前> <stdin の入力> [期待の終了コード (既定 0)]: 出力を <名前>.out に
setup() {
    local name=$1 input=$2 want=${3:-0} rc=0
    echo "case: $name"
    printf '%s' "$input" | HOME="$work/home" PATH="$work/bin:$PATH" bash "$scripts_dir/setup-remote-ssh.sh" > "$work/$name.out" 2>&1 || rc=$?
    if [ "$rc" -ne "$want" ]; then
        fail "$name: rc=$rc, want $want: $(tail -3 "$work/$name.out")"
    fi
}

# config の Host <名前> の節 (Host の行と、その後の字下げした行)
host_block() {
    awk -v host="$1" '/^Host / { inside = ($2 == host) } inside && (/^Host / || /^   /)' "$ssh_dir/config"
}

proxy_of() {
    host_block "$1" | sed -n 's/^   ProxyCommand "\(.*\)" %h .*/\1/p'
}

echo "old shared script" > "$ssh_dir/start-ec2-and-wait.sh"

# 1. alpha: そのホストのスクリプトができ、ProxyCommand がそれを指す。ホスト名は小文字になる
setup alpha $'ws-alpha-instance\nAlpha\nap-northeast-1\n'
alpha_script="$ssh_dir/ec2-workstation-proxy-alpha.sh"
if ! cmp -s "$scripts_dir/start-ec2-and-wait.sh" "$alpha_script" || [ ! -x "$alpha_script" ]; then
    fail "alpha: $alpha_script is not an executable copy of start-ec2-and-wait.sh"
fi
if [ "$(proxy_of alpha)" != "$alpha_script" ]; then
    fail "alpha: ProxyCommand is '$(proxy_of alpha)', want $alpha_script"
fi
if ! host_block alpha | grep -qx '   HostName ws-alpha-instance' || ! host_block alpha | grep -qx '   User ec2-user'; then
    fail "alpha: unexpected Host block: $(host_block alpha)"
fi
if ! grep -qF "'alpha' runs $alpha_script" "$work/alpha.out" || ! grep -qF 'run this setup again for that host' "$work/alpha.out"; then
    fail "alpha: the last message does not name the script or say how to update it: $(tail -2 "$work/alpha.out")"
fi

# 2. beta: alpha のスクリプト (古い版のつもりで目印を足す) と節の中身は変わらない。共有の古いスクリプトも残る
echo "# older alpha" >> "$alpha_script"
cp "$alpha_script" "$work/alpha-before"
host_block alpha > "$work/alpha-block-before"
# 合わない名前は聞き直す
setup beta $'ws-beta-instance\nbad name\nbeta\nap-northeast-1\n'
if ! grep -q "Error: Host name must" "$work/beta.out"; then
    fail "beta: a bad host name is not refused"
fi
beta_script="$ssh_dir/ec2-workstation-proxy-beta.sh"
if [ "$(proxy_of beta)" != "$beta_script" ] || [ ! -x "$beta_script" ]; then
    fail "beta: ProxyCommand is '$(proxy_of beta)', want $beta_script"
fi
if ! cmp -s "$work/alpha-before" "$alpha_script"; then
    fail "beta: the setup for beta changed $alpha_script"
fi
if [ "$(host_block alpha)" != "$(cat "$work/alpha-block-before")" ]; then
    fail "beta: the setup for beta changed Host alpha: $(host_block alpha)"
fi
if [ "$(cat "$ssh_dir/start-ec2-and-wait.sh")" != "old shared script" ]; then
    fail "beta: the old shared start-ec2-and-wait.sh changed"
fi

# 3. alpha をもう一度: alpha のスクリプトだけが新しい版になり、Host alpha は 1 つだけ
# beta のスクリプトが無くても、テストを止めずに残りを見る
cp "$beta_script" "$work/beta-before" 2> /dev/null || fail "alpha-again: $beta_script is missing"
setup alpha-again $'ws-alpha-instance\nalpha\nap-northeast-1\n'
if ! cmp -s "$scripts_dir/start-ec2-and-wait.sh" "$alpha_script"; then
    fail "alpha-again: $alpha_script is not the new version"
fi
if [ "$(grep -c '^Host alpha$' "$ssh_dir/config")" -ne 1 ]; then
    fail "alpha-again: want one Host alpha, got $(grep -c '^Host alpha$' "$ssh_dir/config")"
fi
if ! cmp -s "$work/beta-before" "$beta_script" || [ "$(proxy_of beta)" != "$beta_script" ]; then
    fail "alpha-again: the setup for alpha changed beta"
fi
if [ "$(cat "$ssh_dir/start-ec2-and-wait.sh")" != "old shared script" ]; then
    fail "alpha-again: the old shared start-ec2-and-wait.sh changed"
fi

# 4. --version が失敗した道具は、パスと終了コードと出力 (stdout と stderr) を見せて rc=1 で止まる。AWS に触らず、HOME に何も書かない
# setup の出力 (色の符号を除く)
plain_output() {
    sed 's/\x1b\[[0-9;]*m//g' "$work/$1.out"
}
home_snapshot() {
    (cd "$work/home" && find . -type f -exec sha256sum {} + | sort)
}
# version_failed <名前> <表示名> <パス> <終了コード> <出力の 1 行目> <出力の 2 行目>
version_failed() {
    local name=$1 label=$2 path=$3 code=$4 block before
    block="Error: $label failed to run: '$path --version' exited with code $code."$'\n'"    $5"$'\n'"    $6"$'\n'"  Reinstall it, or fix PATH so that a working one comes first."
    before=$(home_snapshot)
    : > "$work/version-args.log"
    FAKE_ARGS_LOG="$work/version-args.log" setup "$name" $'ws-version\nversion\nap-northeast-1\n' 1
    if [[ $'\n'"$(plain_output "$name")"$'\n' != *$'\n'"$block"$'\n'* ]]; then
        fail "$name: want the lines '$block', got: $(plain_output "$name")"
    fi
    if ! plain_output "$name" | grep -qx 'Please install the missing prerequisites and try again.'; then
        fail "$name: want the line 'Please install the missing prerequisites and try again.'"
    fi
    # - OK は残りの 2 つ (Bash ともう 1 つの道具) だけ
    if [ "$(plain_output "$name" | grep -c ' - OK$')" -ne 2 ]; then
        fail "$name: want '- OK' only for Bash and the other tool, got: $(plain_output "$name" | grep ' - OK$')"
    fi
    if [ "$(cat "$work/version-args.log")" != "--version" ]; then
        fail "$name: want the fake aws to receive only --version, got: $(cat "$work/version-args.log")"
    fi
    if [ "$(home_snapshot)" != "$before" ]; then
        fail "$name: files under HOME were written or changed"
    fi
}
FAKE_VERSION_FAIL=1 version_failed aws-version-fails 'AWS CLI v2 (aws)' "$work/bin/aws" 3 'fake aws: version stdout' 'fake aws: version failed'
FAKE_PLUGIN_FAIL=1 version_failed plugin-version-fails 'Session Manager Plugin (session-manager-plugin)' "$work/bin/session-manager-plugin" 4 'fake plugin: version stdout' 'fake plugin: broken'

# 5. 版を stderr に出して 0 を返す道具 (AWS CLI v1 の形) は通る。終了コードだけで決める
FAKE_VERSION_STDERR=1 setup version-on-stderr $'ws-gamma\ngamma\nap-northeast-1\n'
if ! plain_output version-on-stderr | grep -qx '  aws-cli/1.0.0 fake - OK'; then
    fail "version-on-stderr: want the line '  aws-cli/1.0.0 fake - OK', got: $(head -5 "$work/version-on-stderr.out")"
fi

# 6. 何も出さずに 0 を返す道具も通る (空の版を誤りにしない)
FAKE_VERSION_EMPTY=1 setup version-empty $'ws-delta\ndelta\nap-northeast-1\n'
if ! plain_output version-empty | grep -qx '   - OK'; then
    fail "version-empty: want the line '   - OK', got: $(head -5 "$work/version-empty.out")"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
