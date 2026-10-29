#!/usr/bin/env bash
# CodePipeline の apply の段: scripts/tofu-plan.sh が <plan の置き場所> に保存した plan だけを apply する (承認の後)。
# plan を取った後に state が変わっていれば、tofu は古い plan を apply せずに止まる。
# 要るもの: bash・jq・tofu・AWS CLI、AWS の認証 (書き込み)、TF_STATE_BUCKET
#
#   TF_STATE_BUCKET=<bucket> scripts/tofu-apply.sh --network | --users <plan の置き場所>
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

# 引数の誤りを、init (S3 backend) の誤りより先に出す
if [ $# -ne 2 ] || { [ "$1" != --network ] && [ "$1" != --users ]; }; then
    die "usage: TF_STATE_BUCKET=<bucket> $0 --network | --users <plan dir>"
fi
mode=$1
plan_dir=$2
check_environment

# CodePipeline の Retry は同じ (古い) plan でやり直すので、済んだ人の plan が「古い」で必ず止まる。plan から取り直す
retry_hint="Fix the cause and start the pipeline again with Release change (Retry reuses the old plans and stops)"

case "$mode" in
    --network)
        if [ ! -f "$plan_dir/network.tfplan" ]; then
            die "no network plan in $plan_dir (run scripts/tofu-plan.sh --network first)"
        fi
        # 新しいコンテナには .terraform が無いので、plan を取った時と同じ backend で init してから apply する
        init_stack network
        log "network: apply"
        if ! tofu -chdir="$(stack_dir network)" apply -input=false "$plan_dir/network.tfplan"; then
            die "network: apply failed. $retry_hint"
        fi
        ;;
    --users)
        apply_line="" destroy_line=""
        if [ -f "$plan_dir/manifest" ]; then
            apply_line=$(sed -n 's/^apply: //p' "$plan_dir/manifest")
            destroy_line=$(sed -n 's/^destroy: //p' "$plan_dir/manifest")
        fi
        if ! grep -q '^apply: ' "$plan_dir/manifest" 2> /dev/null || ! grep -q '^destroy: ' "$plan_dir/manifest"; then
            die "no valid manifest in $plan_dir (run scripts/tofu-plan.sh --users first)"
        fi
        users=() removed=()
        read -ra users <<< "$apply_line"
        read -ra removed <<< "$destroy_line"
        for name in "${users[@]}" "${removed[@]}"; do
            if [ ! -f "$plan_dir/user-$name.tfplan" ]; then
                die "no plan for $name in $plan_dir"
            fi
        done
        init_stack workstations
        apply_user_stacks "$plan_dir" "$retry_hint" "${users[@]}" -- "${removed[@]}"
        ;;
esac
