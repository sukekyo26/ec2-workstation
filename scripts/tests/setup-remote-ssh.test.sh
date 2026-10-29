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
case "$*" in
    --version) echo "aws-cli/2.0.0 fake" ;;
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
echo 1.2.3
FAKE
chmod +x "$work/bin/aws" "$work/bin/session-manager-plugin"

ssh_dir="$work/home/.ssh"
failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# setup <名前> <stdin の入力>: 終了コードを <名前>.rc に、出力を <名前>.out に
setup() {
    local name=$1 input=$2 rc=0
    echo "case: $name"
    printf '%s' "$input" | HOME="$work/home" PATH="$work/bin:$PATH" bash "$scripts_dir/setup-remote-ssh.sh" > "$work/$name.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name: rc=$rc: $(tail -3 "$work/$name.out")"
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

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
