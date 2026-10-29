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

# state の bucket・key を決めて init する。key を組み立てるのはここだけ。
#   network:      <projectName>/<environment>/network.tfstate
#   workstations: ユーザーごとの workspace。<projectName>/<environment>/users/<username>/<projectName>/<environment>/workstation.tfstate
#                 (S3 backend は <workspace_key_prefix>/<workspace>/<key> と、key のパスをそのまま後ろに付ける)
init_stack() {
    local stack=$1 dir prefix
    local backend=()
    dir=$(stack_dir "$stack")
    prefix=$(jq -er '"\(.projectName)/\(.environment)"' "$CONFIG_FILE")
    case "$stack" in
        network) backend=(-backend-config="key=$prefix/network.tfstate") ;;
        workstations) backend=(-backend-config="key=$prefix/workstation.tfstate" -backend-config="workspace_key_prefix=$prefix/users") ;;
    esac
    # 前に選んだ workspace が消されていると init が止まるので、選択を default に戻す
    rm -f "$dir/.terraform/environment"
    tofu -chdir="$dir" init -input=false -reconfigure \
        -backend-config="bucket=$TF_STATE_BUCKET" \
        "${backend[@]}" \
        -backend-config="region=$STATE_REGION"
}

config_usernames() {
    jq -er '.users[].username' "$CONFIG_FILE"
}

# state を持つユーザーの workspace の一覧 (default を除く)。tofu workspace list の出力を読むのはここだけ:
# 選んでいる workspace には "* "、ほかは空白 2 つの字下げ、最後に空行が付く。単語では分けない (* がファイル名に展開される)
user_workspaces() {
    local out
    out=$(tofu -chdir="$(stack_dir workstations)" workspace list)
    sed -E 's/^[* ] *//; /^$/d; /^default$/d' <<< "$out"
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

# plan の JSON の要約 (作る・変える・作り直す・消すの数と、作り直すアドレス) を出す。変更が無ければ rc=1
summarize_plan() {
    local label=$1 plan_json=$2 rc=0
    jq -e '[(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length > 0' \
        <<< "$plan_json" > /dev/null || rc=$?
    case $rc in
        0) ;;
        1)
            log "$label: no changes"
            return 1
            ;;
        *) die "could not read the $label plan (jq exit $rc)" ;;
    esac
    jq -r --arg label "$label" '
        [(.resource_changes // [])[] | {address, a: (.change.actions | join(","))}] as $c
        | ($c | map(select(.a == "delete,create" or .a == "create,delete"))) as $replace
        | "\($label): create \($c | map(select(.a == "create")) | length), update \($c | map(select(.a == "update")) | length), replace \($replace | length), delete \($c | map(select(.a == "delete")) | length)",
          ($replace[] | "  replace: \(.address)")' <<< "$plan_json" >&2
}

# 端末なら "yes" を待つ。yes 以外なら何も apply せずに止まる。端末でなければ確かめない
confirm_apply() {
    local label=$1 answer=""
    if ! is_terminal; then
        return 0
    fi
    printf 'Apply the %s plan above? Only "yes" applies: ' "$label" >&2
    read -r answer || true
    if [ "$answer" != yes ]; then
        die "$label: not applied"
    fi
}

# 1 つの plan を要約し、変更があれば確かめる (変更の無い plan は apply しても何も起きないので確かめない)
confirm_plan() {
    if summarize_plan "$1" "$2"; then
        confirm_apply "$1"
    fi
}

# 1 つ目の引数が、残りの引数のどれかと同じなら rc=0
in_list() {
    local want=$1 item
    shift
    for item in "$@"; do
        if [ "$item" = "$want" ]; then
            return 0
        fi
    done
    return 1
}

# ユーザーの workspace ごとに plan を保存し (1 つでも失敗したら何も apply しない)、要約を出して確かめ、全部を apply する。
# destroy したユーザーの workspace は、apply の後に消す。init_stack workstations の後に呼ぶ
#   apply_user_plans <plan の置き場所> <apply するユーザー...> -- <destroy するユーザー...>
apply_user_plans() {
    local plan_dir=$1 dir u plan_json changes=1
    local apply_users=() destroy_users=()
    shift
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        apply_users+=("$1")
        shift
    done
    if [ $# -gt 0 ]; then
        shift
    fi
    destroy_users=("$@")
    dir=$(stack_dir workstations)

    for u in "${apply_users[@]}"; do
        log "workstations/$u: plan"
        tofu -chdir="$dir" workspace select -or-create "$u"
        tofu -chdir="$dir" plan -input=false -out="$plan_dir/user-$u.tfplan"
        plan_json=$(tofu -chdir="$dir" show -json "$plan_dir/user-$u.tfplan")
        if summarize_plan "workstations/$u" "$plan_json"; then
            changes=0
        fi
    done
    # data source (AMI の SSM パラメータ・VPC の検索) を読まずに、state にあるものを消す
    for u in "${destroy_users[@]}"; do
        log "workstations/$u: plan -destroy"
        tofu -chdir="$dir" workspace select "$u"
        tofu -chdir="$dir" plan -destroy -refresh=false -input=false -out="$plan_dir/user-$u.tfplan"
        plan_json=$(tofu -chdir="$dir" show -json "$plan_dir/user-$u.tfplan")
        if summarize_plan "workstations/$u" "$plan_json"; then
            changes=0
        fi
    done
    if [ "$changes" -eq 0 ]; then
        confirm_apply workstations
    fi

    for u in "${apply_users[@]}" "${destroy_users[@]}"; do
        log "workstations/$u: apply"
        tofu -chdir="$dir" workspace select "$u"
        tofu -chdir="$dir" apply -input=false "$plan_dir/user-$u.tfplan"
    done
    if [ ${#destroy_users[@]} -gt 0 ]; then
        # 選んでいる workspace は消せない
        tofu -chdir="$dir" workspace select default
        for u in "${destroy_users[@]}"; do
            log "workstations/$u: delete the workspace"
            tofu -chdir="$dir" workspace delete "$u"
        done
    fi
}
