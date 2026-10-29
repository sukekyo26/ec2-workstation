#!/usr/bin/env bash
# CodePipeline の plan の段: plan だけを取り、<plan の置き場所> に保存する (apply は scripts/tofu-apply.sh、承認の後)。
# 要るもの: bash・jq・tofu・AWS CLI・jv、AWS の認証 (読むだけと state への書き込み)、TF_STATE_BUCKET
#
#   --network: network の plan を network.tfplan に。VPC・サブネットの作り直し・削除なら止まる
#   --users:   全員の plan と、設定から消えた人の destroy の plan を user-<名前>.tfplan に、apply する人と消える人を manifest に。
#              network に apply していない変更が残っていれば止まる (全員の plan は今の network を引くため)
# どちらも <plan の置き場所>/vars に、変更の有無・要約・承認の文を書く (buildspec が CodePipeline の変数にする)
#
#   TF_STATE_BUCKET=<bucket> scripts/tofu-plan.sh --network | --users <plan の置き場所>
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

if [ $# -ne 2 ]; then
    die "usage: TF_STATE_BUCKET=<bucket> $0 --network | --users <plan dir>"
fi
mode=$1
plan_dir=$2
mkdir -p "$plan_dir"

check_environment
validate_config
init_stack network

case "$mode" in
    --network)
        refuse_leftover_vpc
        refuse_leftover_shared_workstations_state
        plan_network "$plan_dir"
        summarize_plan network "$NETWORK_PLAN_JSON"
        read -r c u r d <<< "$(plan_counts "$NETWORK_PLAN_JSON")"
        changed=false
        if [ "$PLAN_CHANGED" -eq 1 ]; then
            changed=true
        fi
        write_pipeline_vars "$plan_dir" "$changed" "network / replace: $r / delete: $d / create: $c / update: $u"
        ;;
    --users)
        # network の段を飛ばした後に、別の所で network が変わっていれば、全員の plan はその変更を前提にできない
        check_dir=$(mktemp -d)
        trap 'rm -rf "$check_dir"' EXIT
        plan_network "$check_dir"
        if plan_has_changes network "$NETWORK_PLAN_JSON"; then
            die "the network has changes that are not applied. Start the pipeline again with Release change (the network stage plans and applies them first)"
        fi

        init_stack workstations
        find_users
        plan_user_stacks "$plan_dir" "${USERS[@]}" -- "${REMOVED[@]}"
        printf 'apply: %s\ndestroy: %s\n' "${USERS[*]}" "${REMOVED[*]}" > "$plan_dir/manifest"

        # 要約は危ない情報 (消える人・作り直し・削除) を先に置く (承認の文は長ければ末尾から切られる)
        create=0 update=0 replace=0 delete=0 replaced=()
        for name in "${USERS[@]}" "${REMOVED[@]}"; do
            read -r c u r d <<< "${USER_COUNTS[$name]}"
            create=$((create + c)) update=$((update + u)) replace=$((replace + r)) delete=$((delete + d))
            if [ "$r" -gt 0 ]; then
                replaced+=("$name")
            fi
        done
        changed=false
        # 消える人がいれば、destroy の plan が空でも workspace を消すので、承認と apply を通す
        if [ "$USER_CHANGES" -gt 0 ] || [ ${#REMOVED[@]} -gt 0 ]; then
            changed=true
        fi
        write_pipeline_vars "$plan_dir" "$changed" \
            "removed: ${REMOVED[*]:-none} / replace: $replace (${replaced[*]:-none}) / delete: $delete / create: $create / update: $update"
        ;;
    *) die "usage: TF_STATE_BUCKET=<bucket> $0 --network | --users <plan dir>" ;;
esac
log "plan saved in $plan_dir: $(cat "$plan_dir/vars/summary")"
