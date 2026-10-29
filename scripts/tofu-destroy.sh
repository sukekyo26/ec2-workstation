#!/usr/bin/env bash
# 全部を消す: workstations → network の順。どの CI からも、手元からも、これを呼べば同じになる。
# 要るもの: bash・jq・tofu、AWS の認証、TF_STATE_BUCKET
#
# destroy の plan は -refresh=false で取る。data source (AMI の SSM パラメータ・VPC の検索) が
# 失敗する状態でも、state にあるものを消せる
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

require_no_tf_workspace
require_state_bucket

# plan のファイルには state と同じく秘密鍵が入るので、終わったら消す
plan_dir=$(mktemp -d)
trap 'rm -rf "$plan_dir"' EXIT

for stack in workstations network; do
    dir=$(stack_dir "$stack")
    log "$stack: plan -destroy"
    "$(dirname "$0")/tofu-init.sh" "$stack"
    tofu -chdir="$dir" plan -destroy -refresh=false -input=false -out="$plan_dir/$stack.tfplan"
    log "$stack: apply"
    tofu -chdir="$dir" apply -input=false "$plan_dir/$stack.tfplan"
done
