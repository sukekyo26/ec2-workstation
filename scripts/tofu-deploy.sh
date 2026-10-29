#!/usr/bin/env bash
# 全員分を deploy する。どの CI からも、手元からも、これを呼べば同じになる。
# 要るもの: bash・jq・tofu・AWS CLI、AWS の認証、TF_STATE_BUCKET
#
# 1 段目: network を plan → apply する (workstations の plan は network の VPC・サブネットを引くため、先に要る)
# 2 段目: workstations を plan → apply する
# どの段も、保存した plan だけを apply する (plan と apply の間で中身が変わらない)
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

require_no_tf_workspace
require_state_bucket

# plan のファイルには state と同じく秘密鍵が入るので、終わったら消す
plan_dir=$(mktemp -d)
trap 'rm -rf "$plan_dir"' EXIT

network_dir=$(stack_dir network)
workstations_dir=$(stack_dir workstations)

# network の state が空なのに同じ Name の VPC があれば、古い形の環境が残っている。
# そのまま進むと 2 組目の VPC を作り、workstations の plan が "multiple EC2 VPCs matched" で止まる
refuse_leftover_vpc() {
    local state_json resource_count vpc_name vpc_count
    state_json=$(tofu -chdir="$network_dir" show -json)
    resource_count=$(jq -e '[.. | objects | select(has("mode") and has("type"))] | length' <<< "$state_json")
    if [ "$resource_count" -ne 0 ]; then
        return 0
    fi
    vpc_name=$(tofu -chdir="$network_dir" console <<< 'module.config.vpc_name' | jq -er .)
    vpc_count=$(aws ec2 describe-vpcs --region "$STATE_REGION" --filters "Name=tag:Name,Values=$vpc_name" --query 'length(Vpcs)' --output text)
    if [ "$vpc_count" -ne 0 ]; then
        die "a VPC named $vpc_name already exists, but the network state is empty. Destroy the old environment with the version of this repository that created it, then deploy again"
    fi
}

# VPC・サブネットの作り直し・削除は、ユーザーのインスタンス・ENI・データボリューム (AZ に固定) を抱えたまま進められない
refuse_network_replacement() {
    local plan_json rc=0
    plan_json=$(tofu -chdir="$network_dir" show -json "$1")
    jq -e '[(.resource_changes // [])[] | select(.type == "aws_vpc" or .type == "aws_subnet")
            | select(.change.actions | index("delete"))] | length > 0' <<< "$plan_json" > /dev/null || rc=$?
    case $rc in
        0) die "the network plan replaces or deletes the VPC or subnet that the workstations use. Run scripts/tofu-destroy.sh first, then scripts/tofu-deploy.sh" ;;
        1) ;;
        *) die "could not read the network plan (jq exit $rc)" ;;
    esac
}

log "network: plan"
"$(dirname "$0")/tofu-init.sh" network
refuse_leftover_vpc
tofu -chdir="$network_dir" plan -input=false -out="$plan_dir/network.tfplan"
refuse_network_replacement "$plan_dir/network.tfplan"
log "network: apply"
tofu -chdir="$network_dir" apply -input=false "$plan_dir/network.tfplan"

log "workstations: plan"
"$(dirname "$0")/tofu-init.sh" workstations
tofu -chdir="$workstations_dir" plan -input=false -out="$plan_dir/workstations.tfplan"
log "workstations: apply"
tofu -chdir="$workstations_dir" apply -input=false "$plan_dir/workstations.tfplan"
