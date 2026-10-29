# shellcheck shell=bash
# tofu-init.sh・tofu-deploy.sh・tofu-destroy.sh が読む共通の部品。
# set -e の下で読まれるので、関数は `[ ... ] && cmd` の形で終わらせない (条件が偽のとき rc=1 で呼び出し元が止まる)

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIG_FILE="$REPO_ROOT/workstation-config.json"
STACKS_DIR="$REPO_ROOT/opentofu/stacks"
# state のバケットのリージョン (デプロイ先のリージョンは workstation-config.json の awsRegion)
STATE_REGION=ap-northeast-1

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "==> $*" >&2
}

# 入口 (tofu-init.sh・tofu-deploy.sh・tofu-destroy.sh) が最初に 1 回だけ呼ぶ
check_environment() {
    # TF_WORKSPACE は workspace の選択を上書きし、state の key を黙って変える
    if [ -n "${TF_WORKSPACE:-}" ]; then
        die "unset TF_WORKSPACE: it overrides the workspace OpenTofu selects, so the state would be read from another key"
    fi
    if [ -z "${TF_STATE_BUCKET:-}" ]; then
        die "set TF_STATE_BUCKET to the S3 bucket that keeps the OpenTofu state (see opentofu/README.md)"
    fi
}

stack_dir() {
    case "$1" in
        network | workstations) echo "$STACKS_DIR/$1" ;;
        *) die "unknown stack '$1' (network or workstations)" ;;
    esac
}

# state の bucket・key を決めて init する。key を組み立てるのはここだけ (<projectName>/<environment>/<stack>.tfstate)
init_stack() {
    local stack=$1 dir prefix
    dir=$(stack_dir "$stack")
    prefix=$(jq -er '"\(.projectName)/\(.environment)"' "$CONFIG_FILE")
    # 前に選んだ workspace が消されていると init が止まるので、選択を default に戻す
    rm -f "$dir/.terraform/environment"
    tofu -chdir="$dir" init -input=false -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        -backend-config="key=$prefix/$stack.tfstate" \
        -backend-config="region=$STATE_REGION"
}

# network の state が空なのに同じ Name の VPC があれば、前の形 (state の key が違う) の環境が残っている。
# deploy は 2 組目の VPC を作り、destroy は何も消さずに「成功」してしまうので、どちらも先に止める。
# init_stack network の後に呼ぶ
refuse_leftover_vpc() {
    local dir state_json resource_count names vpc_name region vpc_count
    dir=$(stack_dir network)
    state_json=$(tofu -chdir="$dir" show -json)
    resource_count=$(jq -e '[.. | objects | select(has("mode") and has("type"))] | length' <<< "$state_json")
    if [ "$resource_count" -ne 0 ]; then
        return 0
    fi
    names=$(tofu -chdir="$dir" console <<< 'jsonencode({vpc_name = module.config.vpc_name, aws_region = module.config.aws_region})' | jq -er 'fromjson')
    vpc_name=$(jq -er .vpc_name <<< "$names")
    region=$(jq -er .aws_region <<< "$names")
    vpc_count=$(aws ec2 describe-vpcs --region "$region" --filters "Name=tag:Name,Values=$vpc_name" --query 'length(Vpcs)' --output text)
    if [ "$vpc_count" -ne 0 ]; then
        die "a VPC named $vpc_name exists in $region, but the network state is empty: an environment created by an earlier version of this repository is left. Destroy it with that version (tofu destroy), then run this again"
    fi
}

# 標準入力と標準出力が端末なら、apply の前に確かめる。CI などの端末でないときは確かめない。
# EC2WS_ASSUME_TERMINAL (yes|no) はテストが端末のふりをするためのもの
is_terminal() {
    case "${EC2WS_ASSUME_TERMINAL:-}" in
        yes) return 0 ;;
        no) return 1 ;;
    esac
    [ -t 0 ] && [ -t 1 ]
}

# plan の JSON を要約して出し、端末なら "yes" を待つ。変更が無い plan は確かめずに通す (apply しても何も起きない)
confirm_plan() {
    local label=$1 plan_json=$2 rc=0 answer=""
    jq -e '[(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length > 0' \
        <<< "$plan_json" > /dev/null || rc=$?
    case $rc in
        0) ;;
        1)
            log "$label: no changes"
            return 0
            ;;
        *) die "could not read the $label plan (jq exit $rc)" ;;
    esac
    jq -r --arg label "$label" '
        [(.resource_changes // [])[] | {address, a: (.change.actions | join(","))}] as $c
        | ($c | map(select(.a == "delete,create" or .a == "create,delete"))) as $replace
        | "\($label): create \($c | map(select(.a == "create")) | length), update \($c | map(select(.a == "update")) | length), replace \($replace | length), delete \($c | map(select(.a == "delete")) | length)",
          ($replace[] | "  replace: \(.address)")' <<< "$plan_json" >&2
    if ! is_terminal; then
        return 0
    fi
    printf 'Apply the %s plan above? Only "yes" applies: ' "$label" >&2
    read -r answer || true
    if [ "$answer" != yes ]; then
        die "$label: not applied"
    fi
}
