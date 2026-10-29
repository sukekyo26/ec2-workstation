#!/usr/bin/env bash
# 全員分を deploy する。どの CI からも、手元からも、これを呼べば同じになる。
# 要るもの: bash・jq・tofu・AWS CLI、AWS の認証、TF_STATE_BUCKET
#
# 1 段目: network を plan → apply する (workstations の plan は network の VPC・サブネットを引くため、先に要る)
# 2 段目: workstations を plan → apply する
# どの段も、保存した plan だけを apply する (plan と apply の間で中身が変わらない)。
# 端末で動かしたときは、変更のある段ごとに plan の要約を出し、"yes" を待つ
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

check_environment

# plan のファイルには state と同じく秘密鍵が入るので、終わったら消す
plan_dir=$(mktemp -d)
trap 'rm -rf "$plan_dir"' EXIT

network_dir=$(stack_dir network)
workstations_dir=$(stack_dir workstations)

# VPC・サブネットの作り直し・削除は、ユーザーのインスタンス・ENI・データボリューム (AZ に固定) を抱えたまま進められない
refuse_network_replacement() {
    local plan_json=$1 rc=0
    jq -e '[(.resource_changes // [])[] | select(.type == "aws_vpc" or .type == "aws_subnet")
            | select(.change.actions | index("delete"))] | length > 0' <<< "$plan_json" > /dev/null || rc=$?
    case $rc in
        0) die "the network plan replaces or deletes the VPC or subnet that the workstations use. Run scripts/tofu-destroy.sh first, then scripts/tofu-deploy.sh" ;;
        1) ;;
        *) die "could not read the network plan (jq exit $rc)" ;;
    esac
}

log "network: plan"
init_stack network
refuse_leftover_vpc
tofu -chdir="$network_dir" plan -input=false -out="$plan_dir/network.tfplan"
plan_json=$(tofu -chdir="$network_dir" show -json "$plan_dir/network.tfplan")
refuse_network_replacement "$plan_json"
confirm_plan network "$plan_json"
log "network: apply"
tofu -chdir="$network_dir" apply -input=false "$plan_dir/network.tfplan"

log "workstations: plan"
init_stack workstations
tofu -chdir="$workstations_dir" plan -input=false -out="$plan_dir/workstations.tfplan"
plan_json=$(tofu -chdir="$workstations_dir" show -json "$plan_dir/workstations.tfplan")
confirm_plan workstations "$plan_json"
log "workstations: apply"
tofu -chdir="$workstations_dir" apply -input=false "$plan_dir/workstations.tfplan"
