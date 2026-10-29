#!/usr/bin/env bash
# 全員分を deploy する。どの CI からも、手元からも、これを呼べば同じになる。
# 要るもの: bash・jq・tofu・AWS CLI・jv (scripts/install-jv.sh)、AWS の認証、TF_STATE_BUCKET
#
# 1 段目: network を plan → apply する (workstations の plan は network の VPC・サブネットを引くため、先に要る)
# 2 段目: 設定にいる全員の plan と、設定から消えたユーザー (state だけが残る workspace) の destroy の plan を取り、
#         1 つでも失敗したら何も apply しない。全部通ったら apply し、消えたユーザーの workspace を消す
# どの段も、保存した plan だけを apply する (plan と apply の間で中身が変わらない)。
# 端末で動かしたときは、変更のある段ごとに plan の要約を出し、"yes" を待つ
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

check_environment
validate_config

# plan のファイルには state と同じく秘密鍵が入るので、終わったら消す
plan_dir=$(mktemp -d)
trap 'rm -rf "$plan_dir"' EXIT

init_stack network
refuse_leftover_vpc
refuse_leftover_shared_workstations_state

# 消える人は、何かを apply する前に決める (一覧を取れなければ、ここで止まる)
init_stack workstations
find_users

plan_network "$plan_dir"
confirm_plan network "$NETWORK_PLAN_JSON"
log "network: apply"
tofu -chdir="$(stack_dir network)" apply -input=false "$plan_dir/network.tfplan"

apply_user_plans "$plan_dir" "${USERS[@]}" -- "${REMOVED[@]}"
