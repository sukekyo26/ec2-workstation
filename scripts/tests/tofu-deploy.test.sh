#!/usr/bin/env bash
# scripts/tofu-deploy.sh・scripts/tofu-destroy.sh の順番と止まり方を、偽の tofu・aws で確かめる。
# 偽のものは一時ディレクトリに実行できるファイルとして置き、PATH の先頭に足す
# (シェルの関数は scripts/tofu-init.sh などの子プロセスに届かないため)。
#
#   scripts/tests/tofu-deploy.test.sh
set -euo pipefail

scripts_dir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

cat > "$work/bin/tofu" << 'FAKE'
#!/usr/bin/env bash
# 偽の tofu: 呼ばれたコマンドを "<stack> <args>" で $FAKE_LOG に 1 行ずつ書く。plan のファイルはパスを落として名前だけ書く
set -euo pipefail
stack=$(basename "${1#-chdir=}")
shift
args=()
for a in "$@"; do
    case "$a" in
        -out=*) args+=("-out=$(basename "${a#-out=}")") ;;
        *.tfplan) args+=("$(basename "$a")") ;;
        *) args+=("$a") ;;
    esac
done
echo "$stack ${args[*]}" >> "$FAKE_LOG"

case "$1" in
    init) ;;
    console) echo '"ec2-workstation-dev-vpc"' ;;
    show)
        if [ $# -eq 2 ]; then
            # show -json だけなら state
            if [ "${FAKE_NETWORK_STATE_EMPTY:-}" = 1 ]; then
                echo '{"format_version":"1.0"}'
            else
                echo '{"format_version":"1.0","values":{"root_module":{"child_modules":[{"resources":[{"address":"module.network.aws_vpc.this","mode":"managed","type":"aws_vpc"}]}]}}}'
            fi
        else
            if [ "${FAKE_SHOW_PLAN:-}" = fail ]; then
                exit 1
            fi
            no_change='{"resource_changes":[{"type":"aws_vpc","change":{"actions":["no-op"]}}]}'
            echo "${FAKE_SHOW_PLAN:-$no_change}"
        fi
        ;;
    plan)
        if [ "${FAKE_PLAN_FAIL:-}" = "$stack" ]; then
            exit 1
        fi
        for a in "$@"; do
            case "$a" in -out=*) echo "$stack" > "${a#-out=}" ;; esac
        done
        ;;
    apply)
        # 保存した plan だけを、その plan を取ったルートで apply する
        planfile=${*: -1}
        if [ ! -f "$planfile" ] || [ "$(cat "$planfile")" != "$stack" ]; then
            echo "fake tofu: apply in $stack needs a plan file saved by plan in $stack: $planfile" >&2
            exit 1
        fi
        ;;
    *)
        echo "fake tofu: unexpected command: $*" >&2
        exit 1
        ;;
esac
FAKE

cat > "$work/bin/aws" << 'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "aws $*" >> "$FAKE_LOG"
echo "${FAKE_VPC_COUNT:-0}"
FAKE
chmod +x "$work/bin/tofu" "$work/bin/aws"

export PATH="$work/bin:$PATH"
if [ "$(command -v tofu)" != "$work/bin/tofu" ] || [ "$(command -v aws)" != "$work/bin/aws" ]; then
    echo "the fake tofu or aws is not first on PATH" >&2
    exit 1
fi

failures=0

# run <name> <script> [VAR=value ...]: 偽の環境でスクリプトを走らせ、rc・ログ・標準エラーを $work に残す
run() {
    local name=$1 script=$2
    shift 2
    export FAKE_LOG="$work/$name.log"
    : > "$FAKE_LOG"
    local rc=0
    env TF_STATE_BUCKET=test-bucket "$@" "$scripts_dir/$script" > /dev/null 2> "$work/$name.err" || rc=$?
    echo "$rc" > "$work/$name.rc"
}

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

expect_rc() {
    local name=$1 want=$2 got
    got=$(cat "$work/$name.rc")
    if [ "$got" != "$want" ]; then
        fail "$name: exit code $got, want $want"
        sed 's/^/    /' "$work/$name.err" >&2
    fi
}

expect_log() {
    local name=$1 want=$2
    # 空の期待は「1 度も呼ばれない」
    if ! diff <(if [ -n "$want" ]; then printf '%s\n' "$want"; fi) "$work/$name.log" > "$work/$name.diff"; then
        fail "$name: commands differ from the expected ones (- want, + got)"
        sed 's/^/    /' "$work/$name.diff" >&2
    fi
}

expect_err() {
    local name=$1 want=$2
    if ! grep -qF -- "$want" "$work/$name.err"; then
        fail "$name: stderr does not contain: $want"
        sed 's/^/    /' "$work/$name.err" >&2
    fi
}

init_network="network init -input=false -reconfigure -backend-config=bucket=test-bucket -backend-config=key=ec2-workstation/dev/network.tfstate -backend-config=region=ap-northeast-1"
init_workstations="workstations init -input=false -reconfigure -backend-config=bucket=test-bucket -backend-config=key=ec2-workstation/dev/workstations.tfstate -backend-config=region=ap-northeast-1"

# --- deploy ---

run deploy tofu-deploy.sh
expect_rc deploy 0
expect_log deploy "$init_network
network show -json
network plan -input=false -out=network.tfplan
network show -json network.tfplan
network apply -input=false network.tfplan
$init_workstations
workstations plan -input=false -out=workstations.tfplan
workstations apply -input=false workstations.tfplan"

# workstations の plan が失敗したら workstations は apply しない。network の apply はその前に 1 回だけ
run deploy-workstations-plan-fails tofu-deploy.sh FAKE_PLAN_FAIL=workstations
expect_rc deploy-workstations-plan-fails 1
expect_log deploy-workstations-plan-fails "$init_network
network show -json
network plan -input=false -out=network.tfplan
network show -json network.tfplan
network apply -input=false network.tfplan
$init_workstations
workstations plan -input=false -out=workstations.tfplan"

run deploy-network-plan-fails tofu-deploy.sh FAKE_PLAN_FAIL=network
expect_rc deploy-network-plan-fails 1
expect_log deploy-network-plan-fails "$init_network
network show -json
network plan -input=false -out=network.tfplan"

# VPC・サブネットの作り直し・削除は apply せずに止まる
for actions in '"delete","create"' '"create","delete"' '"delete"'; do
    for type in aws_vpc aws_subnet; do
        name="deploy-replace-$type-$(tr -dc '[:lower:]' <<< "$actions")"
        run "$name" tofu-deploy.sh "FAKE_SHOW_PLAN={\"resource_changes\":[{\"type\":\"aws_flow_log\",\"change\":{\"actions\":[\"update\"]}},{\"type\":\"$type\",\"change\":{\"actions\":[$actions]}}]}"
        expect_rc "$name" 1
        expect_log "$name" "$init_network
network show -json
network plan -input=false -out=network.tfplan
network show -json network.tfplan"
        expect_err "$name" "Run scripts/tofu-destroy.sh first, then scripts/tofu-deploy.sh"
    done
done

# 作る・in-place の変更・変更なしの plan は進む
for plan in '{"resource_changes":[{"type":"aws_vpc","change":{"actions":["create"]}},{"type":"aws_subnet","change":{"actions":["create"]}}]}' \
    '{"resource_changes":[{"type":"aws_subnet","change":{"actions":["update"]}}]}' \
    '{"format_version":"1.2"}'; do
    run deploy-network-plan-ok tofu-deploy.sh "FAKE_SHOW_PLAN=$plan"
    expect_rc deploy-network-plan-ok 0
done

# plan を読めなければ apply しない
for show in fail 'not json'; do
    run deploy-show-broken tofu-deploy.sh "FAKE_SHOW_PLAN=$show"
    expect_rc deploy-show-broken 1
    expect_log deploy-show-broken "$init_network
network show -json
network plan -input=false -out=network.tfplan
network show -json network.tfplan"
done

# network の state が空で、同じ Name の VPC が残っていれば、plan の前に止まる
run deploy-leftover-vpc tofu-deploy.sh FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=1
expect_rc deploy-leftover-vpc 1
expect_log deploy-leftover-vpc "$init_network
network show -json
network console
aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=ec2-workstation-dev-vpc --query length(Vpcs) --output text"
expect_err deploy-leftover-vpc "Destroy the old environment"

# 初めての deploy (state が空で VPC も無い) は進む
run deploy-first tofu-deploy.sh FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=0
expect_rc deploy-first 0
expect_log deploy-first "$init_network
network show -json
network console
aws ec2 describe-vpcs --region ap-northeast-1 --filters Name=tag:Name,Values=ec2-workstation-dev-vpc --query length(Vpcs) --output text
network plan -input=false -out=network.tfplan
network show -json network.tfplan
network apply -input=false network.tfplan
$init_workstations
workstations plan -input=false -out=workstations.tfplan
workstations apply -input=false workstations.tfplan"

# TF_WORKSPACE と TF_STATE_BUCKET の誤りは、tofu を呼ぶ前に止まる
for script in tofu-deploy.sh tofu-destroy.sh; do
    run "$script-tf-workspace" "$script" TF_WORKSPACE=developer1
    expect_rc "$script-tf-workspace" 1
    expect_log "$script-tf-workspace" ""
    expect_err "$script-tf-workspace" "unset TF_WORKSPACE"

    run "$script-no-bucket" "$script" TF_STATE_BUCKET=
    expect_rc "$script-no-bucket" 1
    expect_log "$script-no-bucket" ""
    expect_err "$script-no-bucket" "set TF_STATE_BUCKET"
done

# --- destroy ---

run destroy tofu-destroy.sh
expect_rc destroy 0
expect_log destroy "$init_workstations
workstations plan -destroy -refresh=false -input=false -out=workstations.tfplan
workstations apply -input=false workstations.tfplan
$init_network
network plan -destroy -refresh=false -input=false -out=network.tfplan
network apply -input=false network.tfplan"

# workstations を消せなければ network に進まない
run destroy-workstations-fails tofu-destroy.sh FAKE_PLAN_FAIL=workstations
expect_rc destroy-workstations-fails 1
expect_log destroy-workstations-fails "$init_workstations
workstations plan -destroy -refresh=false -input=false -out=workstations.tfplan"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
