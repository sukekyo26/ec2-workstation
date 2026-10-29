#!/usr/bin/env bash
# scripts/start-ec2-and-wait.sh・scripts/start-ec2.sh を、偽の aws で確かめる。
# - start-ec2-and-wait.sh は SSH の ProxyCommand として動くので、stdout にはセッション (偽の aws の SSH-2.0-fake) だけが出る
# - aws の呼び出しが失敗したら、理由を出してすぐ止まる (どの実行も 10 秒で打ち切る)
# - 偽の aws は PATH の先頭に置き、FAKE_STATE で状態を、FAKE_FAIL で失敗させる呼び出しを、FAKE_WARN=1 で成功のときの
#   stderr の警告を選ぶ。stdout に出す呼び出し (describe・start-instances の JSON・start-session) は全部まねる
#
#   scripts/tests/start-ec2.test.sh
set -euo pipefail

scripts_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/out"

cat > "$work/bin/aws" << 'FAKE'
#!/usr/bin/env bash
what=$2
case "$2 ${3:-}" in
    "wait "*) what="wait-$3" ;;
    "describe-instances --region") what=lookup ;;
    "describe-instances --instance-ids") what=state ;;
esac
case "$what" in
    lookup | state | start-instances | wait-instance-stopped | wait-instance-running | describe-instance-information | start-session) ;;
    *)
        echo "fake aws: unexpected call: $*" >&2
        exit 2
        ;;
esac
if [ "${FAKE_FAIL:-}" = "$what" ]; then
    echo "fake aws: $what failed" >&2
    exit 1
fi
if [ "${FAKE_WARN:-}" = 1 ]; then
    echo "fake aws: warning from $what" >&2
fi
case "$what" in
    lookup) echo i-0123456789abcdef0 ;;
    state) echo "$FAKE_STATE" ;;
    start-instances) printf '%s\n' '{' '    "StartingInstances": []' '}' ;;
    describe-instance-information) echo Online ;;
    start-session) echo SSH-2.0-fake ;;
esac
FAKE
chmod +x "$work/bin/aws"
export PATH="$work/bin:$PATH"

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# run <name> <script> [VAR=value ...]: 10 秒で打ち切って走らせ、rc・stdout・stderr を残す (打ち切ったら rc=124)
run() {
    local name=$1 script=$2 rc=0 args=()
    shift 2
    case "$script" in
        start-ec2-and-wait.sh) args=(ws ap-northeast-1 22) ;;
        start-ec2.sh) args=(ws ap-northeast-1) ;;
    esac
    env -u FAKE_STATE -u FAKE_FAIL -u FAKE_WARN "$@" timeout 10 "$scripts_dir/$script" "${args[@]}" \
        < /dev/null > "$work/out/$name.out" 2> "$work/out/$name.err" || rc=$?
    echo "$rc" > "$work/out/$name.rc"
}

rc_of() {
    cat "$work/out/$1.rc"
}

for state in stopped stopping pending running; do
    for warn in 0 1; do
        name="wait-$state-warn$warn"
        run "$name" start-ec2-and-wait.sh "FAKE_STATE=$state" "FAKE_WARN=$warn"
        if [ "$(rc_of "$name")" != 0 ] || [ "$(cat "$work/out/$name.out")" != SSH-2.0-fake ]; then
            fail "$name: want rc=0 and stdout 'SSH-2.0-fake' alone, got rc=$(rc_of "$name") stdout: $(cat "$work/out/$name.out")"
        fi

        name="start-$state-warn$warn"
        run "$name" start-ec2.sh "FAKE_STATE=$state" "FAKE_WARN=$warn"
        if [ "$(rc_of "$name")" != 0 ] || ! grep -qF "EC2 instance is ready" "$work/out/$name.out"; then
            fail "$name: want rc=0 and the ready message, got rc=$(rc_of "$name")"
        fi
    done
done

for c in stopped:start-instances stopped:wait-instance-running stopping:wait-instance-stopped stopping:start-instances \
    stopping:wait-instance-running pending:wait-instance-running running:describe-instance-information; do
    state=${c%%:*} failing=${c#*:}
    reason="fake aws: $failing failed"

    name="wait-$state-$failing"
    run "$name" start-ec2-and-wait.sh "FAKE_STATE=$state" "FAKE_FAIL=$failing"
    if [ "$(rc_of "$name")" != 1 ] || [ -s "$work/out/$name.out" ] || ! grep -qF "$reason" "$work/out/$name.err"; then
        fail "$name: want rc=1 within 10s, empty stdout, and '$reason' on stderr, got rc=$(rc_of "$name") stdout: $(cat "$work/out/$name.out")"
    fi

    name="start-$state-$failing"
    run "$name" start-ec2.sh "FAKE_STATE=$state" "FAKE_FAIL=$failing"
    if [ "$(rc_of "$name")" != 1 ] || ! cat "$work/out/$name.out" "$work/out/$name.err" | grep -qF "$reason"; then
        fail "$name: want rc=1 within 10s and '$reason', got rc=$(rc_of "$name")"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
