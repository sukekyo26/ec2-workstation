#!/usr/bin/env bash
# 全部を消す: workstations → network の順。どの CI からも、手元からも、これを呼べば同じになる。
# 要るもの: bash・jq・tofu・AWS CLI、AWS の認証、TF_STATE_BUCKET
#
# destroy の plan は -refresh=false で取る。data source (AMI の SSM パラメータ・VPC の検索) が
# 失敗する状態でも、state にあるものを消せる。端末で動かしたときは、段ごとに plan の要約を出し、"yes" を待つ
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

check_environment

# plan のファイルには state と同じく秘密鍵が入るので、終わったら消す
plan_dir=$(mktemp -d)
trap 'rm -rf "$plan_dir"' EXIT

# 前の形の環境が残っていれば、新しい state を消しても「成功」するだけで、残りは動き続ける
init_stack network
refuse_leftover_vpc
init_stack workstations

for stack in workstations network; do
    dir=$(stack_dir "$stack")
    log "$stack: plan -destroy"
    tofu -chdir="$dir" plan -destroy -refresh=false -input=false -out="$plan_dir/$stack.tfplan"
    plan_json=$(tofu -chdir="$dir" show -json "$plan_dir/$stack.tfplan")
    confirm_plan "$stack" "$plan_json"
    log "$stack: apply"
    tofu -chdir="$dir" apply -input=false "$plan_dir/$stack.tfplan"
done
