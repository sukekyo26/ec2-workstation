#!/usr/bin/env bash
# scripts/tofu-deploy.sh・scripts/tofu-destroy.sh の順番と止まり方を、偽の tofu・aws で確かめる。
# - スクリプトは一時ディレクトリのリポジトリの形 (scripts/・opentofu/stacks/・workstation-config.json) に写して走らせ、
#   設定はテストが用意したものを読ませる (リポジトリの workstation-config.json の値に頼らない)
# - 偽の tofu・aws は一時ディレクトリに実行できるファイルとして置き、PATH の先頭に足す
#   (シェルの関数は子プロセスに届かないため)
#
#   scripts/tests/tofu-deploy.test.sh
set -euo pipefail

scripts_src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/opentofu/stacks/network" "$repo/opentofu/stacks/workstations" "$work/bin" "$work/out"
cp -R "$scripts_src" "$repo/scripts"
echo '{"projectName": "testproj", "environment": "staging"}' > "$repo/workstation-config.json"

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
    console)
        echo '"{\"aws_region\":\"us-west-2\",\"vpc_name\":\"testproj-staging-vpc\"}"'
        ;;
    show)
        if [ $# -eq 2 ]; then
            # show -json だけなら state
            if [ "${FAKE_NETWORK_STATE_EMPTY:-}" = 1 ]; then
                echo '{"format_version":"1.0"}'
            else
                echo '{"format_version":"1.0","values":{"root_module":{"child_modules":[{"resources":[{"address":"module.network.aws_vpc.this","mode":"managed","type":"aws_vpc"}]}]}}}'
            fi
        else
            var="FAKE_SHOW_PLAN_$stack"
            if [ "${!var:-}" = fail ]; then
                exit 1
            fi
            no_change='{"resource_changes":[{"address":"x","type":"aws_vpc","change":{"actions":["no-op"]}}]}'
            echo "${!var:-$no_change}"
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

# run <name> <script> <stdin> [VAR=value ... | arg ...]: 偽の環境でスクリプトを走らせ、rc・ログ・標準エラーを残す。
# = を含むものは環境変数、ほかはスクリプトの引数。端末でない形で走らせ (EC2WS_ASSUME_TERMINAL=no)、端末のふりは引数で上書きする
run() {
    local name=$1 script=$2 input=$3 a
    shift 3
    local vars=() args=()
    for a in "$@"; do
        case "$a" in
            *=*) vars+=("$a") ;;
            *) args+=("$a") ;;
        esac
    done
    export FAKE_LOG="$work/out/$name.log"
    : > "$FAKE_LOG"
    local rc=0
    printf '%s' "$input" | env TF_STATE_BUCKET=test-bucket EC2WS_ASSUME_TERMINAL=no "${vars[@]}" \
        "$repo/scripts/$script" "${args[@]}" > /dev/null 2> "$work/out/$name.err" || rc=$?
    echo "$rc" > "$work/out/$name.rc"
}

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

expect_rc() {
    local name=$1 want=$2 got
    got=$(cat "$work/out/$name.rc")
    if [ "$got" != "$want" ]; then
        fail "$name: exit code $got, want $want"
        sed 's/^/    /' "$work/out/$name.err" >&2
    fi
}

expect_log() {
    local name=$1 want=$2
    # 空の期待は「1 度も呼ばれない」
    if ! diff <(if [ -n "$want" ]; then printf '%s\n' "$want"; fi) "$work/out/$name.log" > "$work/out/$name.diff"; then
        fail "$name: commands differ from the expected ones (- want, + got)"
        sed 's/^/    /' "$work/out/$name.diff" >&2
    fi
}

expect_err() {
    local name=$1 want=$2
    if ! grep -qF -- "$want" "$work/out/$name.err"; then
        fail "$name: stderr does not contain: $want"
        sed 's/^/    /' "$work/out/$name.err" >&2
    fi
}

expect_no_err() {
    local name=$1 unwanted=$2
    if grep -qF -- "$unwanted" "$work/out/$name.err"; then
        fail "$name: stderr contains: $unwanted"
    fi
}

init_network="network init -input=false -reconfigure -backend-config=bucket=test-bucket -backend-config=key=testproj/staging/network.tfstate -backend-config=region=ap-northeast-1"
init_workstations="workstations init -input=false -reconfigure -backend-config=bucket=test-bucket -backend-config=key=testproj/staging/workstations.tfstate -backend-config=region=ap-northeast-1"
leftover_check="network show -json
network console
aws ec2 describe-vpcs --region us-west-2 --filters Name=tag:Name,Values=testproj-staging-vpc --query length(Vpcs) --output text"
network_plan="network plan -input=false -out=network.tfplan
network show -json network.tfplan"
network_apply="network apply -input=false network.tfplan"
workstations_plan="workstations plan -input=false -out=workstations.tfplan
workstations show -json workstations.tfplan"
workstations_apply="workstations apply -input=false workstations.tfplan"
creates='{"resource_changes":[{"address":"module.a.aws_vpc.this","type":"aws_vpc","change":{"actions":["create"]}},{"address":"module.a.aws_subnet.public","type":"aws_subnet","change":{"actions":["create"]}}]}'
replaces='{"resource_changes":[{"address":"module.workstation[\"dev1\"].aws_instance.this","type":"aws_instance","change":{"actions":["delete","create"]}},{"address":"module.workstation[\"dev1\"].aws_volume_attachment.data","type":"aws_volume_attachment","change":{"actions":["create","delete"]}},{"address":"module.workstation[\"dev1\"].aws_ebs_volume.data","type":"aws_ebs_volume","change":{"actions":["update"]}}]}'

# --- deploy ---

run deploy tofu-deploy.sh ""
expect_rc deploy 0
expect_log deploy "$init_network
network show -json
$network_plan
$network_apply
$init_workstations
$workstations_plan
$workstations_apply"

# workstations の plan が失敗したら workstations は apply しない。network の apply はその前に 1 回だけ
run deploy-workstations-plan-fails tofu-deploy.sh "" FAKE_PLAN_FAIL=workstations
expect_rc deploy-workstations-plan-fails 1
expect_log deploy-workstations-plan-fails "$init_network
network show -json
$network_plan
$network_apply
$init_workstations
workstations plan -input=false -out=workstations.tfplan"

run deploy-network-plan-fails tofu-deploy.sh "" FAKE_PLAN_FAIL=network
expect_rc deploy-network-plan-fails 1
expect_log deploy-network-plan-fails "$init_network
network show -json
network plan -input=false -out=network.tfplan"

# VPC・サブネットの作り直し・削除は apply せずに止まる
for actions in '"delete","create"' '"create","delete"' '"delete"'; do
    for type in aws_vpc aws_subnet; do
        name="deploy-replace-$type-$(tr -dc '[:lower:]' <<< "$actions")"
        run "$name" tofu-deploy.sh "" "FAKE_SHOW_PLAN_network={\"resource_changes\":[{\"address\":\"a\",\"type\":\"aws_flow_log\",\"change\":{\"actions\":[\"update\"]}},{\"address\":\"b\",\"type\":\"$type\",\"change\":{\"actions\":[$actions]}}]}"
        expect_rc "$name" 1
        expect_log "$name" "$init_network
network show -json
$network_plan"
        expect_err "$name" "Run scripts/tofu-destroy.sh first, then scripts/tofu-deploy.sh"
    done
done

# 作る・in-place の変更・resource_changes の無い plan は進む
for plan in "$creates" \
    '{"resource_changes":[{"address":"a","type":"aws_subnet","change":{"actions":["update"]}}]}' \
    '{"format_version":"1.2"}'; do
    run deploy-network-plan-ok tofu-deploy.sh "" "FAKE_SHOW_PLAN_network=$plan"
    expect_rc deploy-network-plan-ok 0
done

# plan を読めなければ apply しない
for stack in network workstations; do
    for show in fail 'not json'; do
        run "deploy-show-broken-$stack" tofu-deploy.sh "" "FAKE_SHOW_PLAN_$stack=$show"
        expect_rc "deploy-show-broken-$stack" 1
        if ! grep -q "^$stack apply" "$work/out/deploy-show-broken-$stack.log"; then
            continue
        fi
        fail "deploy-show-broken-$stack ($show): $stack was applied"
    done
done

# network の state が空で、同じ Name の VPC がデプロイ先のリージョンに残っていれば、plan の前に止まる
run deploy-leftover-vpc tofu-deploy.sh "" FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=1
expect_rc deploy-leftover-vpc 1
expect_log deploy-leftover-vpc "$init_network
$leftover_check"
expect_err deploy-leftover-vpc "Destroy it with that version"

# 初めての deploy (state が空で VPC も無い) は進む
run deploy-first tofu-deploy.sh "" FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=0
expect_rc deploy-first 0
expect_log deploy-first "$init_network
$leftover_check
$network_plan
$network_apply
$init_workstations
$workstations_plan
$workstations_apply"

# 端末: 変更のある段ごとに要約を出し、yes で apply する
run deploy-terminal-yes tofu-deploy.sh $'yes\nyes\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$creates" "FAKE_SHOW_PLAN_workstations=$replaces"
expect_rc deploy-terminal-yes 0
expect_log deploy-terminal-yes "$init_network
network show -json
$network_plan
$network_apply
$init_workstations
$workstations_plan
$workstations_apply"
expect_err deploy-terminal-yes "network: create 2, update 0, replace 0, delete 0"
expect_err deploy-terminal-yes "workstations: create 0, update 1, replace 2, delete 0"
expect_err deploy-terminal-yes '  replace: module.workstation["dev1"].aws_instance.this'
expect_err deploy-terminal-yes '  replace: module.workstation["dev1"].aws_volume_attachment.data'
expect_err deploy-terminal-yes 'Apply the workstations plan above? Only "yes" applies'

# 端末: yes 以外なら apply せずに止まる (1 段目で断れば network も apply しない)
for answer in no '' YES y; do
    run deploy-terminal-no tofu-deploy.sh "$answer" EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$creates"
    expect_rc deploy-terminal-no 1
    expect_log deploy-terminal-no "$init_network
network show -json
$network_plan"
    expect_err deploy-terminal-no "network: not applied"
done

# 端末: 2 段目で断れば workstations は apply しない
run deploy-terminal-no-workstations tofu-deploy.sh $'yes\nno\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$creates" "FAKE_SHOW_PLAN_workstations=$replaces"
expect_rc deploy-terminal-no-workstations 1
expect_log deploy-terminal-no-workstations "$init_network
network show -json
$network_plan
$network_apply
$init_workstations
$workstations_plan"
expect_err deploy-terminal-no-workstations "workstations: not applied"

# 端末: 変更の無い段は確かめない (network は変更なし、workstations だけ確かめる)
run deploy-terminal-no-change tofu-deploy.sh $'yes\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_workstations=$replaces"
expect_rc deploy-terminal-no-change 0
expect_err deploy-terminal-no-change "network: no changes"
expect_no_err deploy-terminal-no-change "Apply the network plan above?"

# 端末でなければ、変更があっても確かめずに進む (要約は出す)
run deploy-not-terminal tofu-deploy.sh "" "FAKE_SHOW_PLAN_network=$creates" "FAKE_SHOW_PLAN_workstations=$replaces"
expect_rc deploy-not-terminal 0
expect_err deploy-not-terminal "workstations: create 0, update 1, replace 2, delete 0"
expect_no_err deploy-not-terminal "Apply the"

# TF_WORKSPACE と TF_STATE_BUCKET の誤りは、tofu を呼ぶ前に止まる
for script in tofu-deploy.sh tofu-destroy.sh tofu-init.sh; do
    args=()
    if [ "$script" = tofu-init.sh ]; then
        args=(network)
    fi
    run "$script-tf-workspace" "$script" "" TF_WORKSPACE=developer1 "${args[@]}"
    expect_rc "$script-tf-workspace" 1
    expect_log "$script-tf-workspace" ""
    expect_err "$script-tf-workspace" "unset TF_WORKSPACE"

    run "$script-no-bucket" "$script" "" TF_STATE_BUCKET= "${args[@]}"
    expect_rc "$script-no-bucket" 1
    expect_log "$script-no-bucket" ""
    expect_err "$script-no-bucket" "set TF_STATE_BUCKET"
done

run init tofu-init.sh "" network
expect_rc init 0
expect_log init "$init_network"

# --- destroy ---

destroys='{"resource_changes":[{"address":"a","type":"aws_vpc","change":{"actions":["delete"]}}]}'

run destroy tofu-destroy.sh "" "FAKE_SHOW_PLAN_network=$destroys" "FAKE_SHOW_PLAN_workstations=$destroys"
expect_rc destroy 0
expect_log destroy "$init_network
network show -json
$init_workstations
workstations plan -destroy -refresh=false -input=false -out=workstations.tfplan
workstations show -json workstations.tfplan
$workstations_apply
network plan -destroy -refresh=false -input=false -out=network.tfplan
network show -json network.tfplan
$network_apply"

# 前の形の環境が残っていれば、何も消さずに止まる (新しい state を消して「成功」しない)
run destroy-leftover-vpc tofu-destroy.sh "" FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=1
expect_rc destroy-leftover-vpc 1
expect_log destroy-leftover-vpc "$init_network
$leftover_check"
expect_err destroy-leftover-vpc "Destroy it with that version"

# workstations を消せなければ network に進まない
run destroy-workstations-fails tofu-destroy.sh "" FAKE_PLAN_FAIL=workstations
expect_rc destroy-workstations-fails 1
expect_log destroy-workstations-fails "$init_network
network show -json
$init_workstations
workstations plan -destroy -refresh=false -input=false -out=workstations.tfplan"

# plan を読めなければ apply しない
run destroy-show-fails tofu-destroy.sh "" FAKE_SHOW_PLAN_workstations=fail
expect_rc destroy-show-fails 1
expect_log destroy-show-fails "$init_network
network show -json
$init_workstations
workstations plan -destroy -refresh=false -input=false -out=workstations.tfplan
workstations show -json workstations.tfplan"

# 端末: 段ごとに yes を待つ。2 段目 (network) で断れば network は消さない
run destroy-terminal tofu-destroy.sh $'yes\nno\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$destroys" "FAKE_SHOW_PLAN_workstations=$destroys"
expect_rc destroy-terminal 1
expect_log destroy-terminal "$init_network
network show -json
$init_workstations
workstations plan -destroy -refresh=false -input=false -out=workstations.tfplan
workstations show -json workstations.tfplan
$workstations_apply
network plan -destroy -refresh=false -input=false -out=network.tfplan
network show -json network.tfplan"
expect_err destroy-terminal "network: create 0, update 0, replace 0, delete 1"
expect_err destroy-terminal "network: not applied"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
