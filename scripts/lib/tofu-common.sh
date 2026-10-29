# shellcheck shell=bash
# tofu-init.sh・tofu-deploy.sh・tofu-destroy.sh・validate-config.sh (と、それを呼ぶ CI・just・テスト) が読む共通の部品。
# tofu・AWS の認証が無い所 (CI の設定の検証) でも読まれるので、トップレベルで tofu・aws・jq を呼ばない。
# die・log・REPO_ROOT・inherit_errexit は scripts/lib/base.sh、jv の版と置き場所は scripts/lib/tools.sh にある

# shellcheck source=scripts/lib/tools.sh
. "$(dirname "${BASH_SOURCE[0]}")/tools.sh"

CONFIG_FILE="$REPO_ROOT/workstation-config.json"
STACKS_DIR="$REPO_ROOT/opentofu/stacks"
# state のバケットのリージョン (デプロイ先のリージョンは workstation-config.json の awsRegion)
STATE_REGION=ap-northeast-1

# workstation-config.json をスキーマで検証する。CI・just・tofu-deploy.sh・tofu-init.sh はここを通る。
# jv は知らないキーワードを黙って無視する (書き間違えた決まりが効かない) ので、先にスキーマそのものを
# schemas/draft-07-strict.json (draft-07 のメタスキーマに additionalProperties: false を足したもの) で見る。
# LIMIT: 見るのは draft-07 に無いキーワードだけ。ajv の strict の残り (strictTypes・strictRequired など、型の書き方の矛盾) は見ない
# jv はどの失敗でも rc=1 を返すので、出力で案内を分ける: スキーマを読めない・コンパイルできないときは "schema <file>: failed"
# (スキーマがメタスキーマに違反するときも - at '...' の行が出るので、先に見る)、設定の違反は - at '...' の行、ほかは設定を読めない
validate_config() {
    local jv out rc=0
    jv=$(jv_path)
    if [ ! -x "$jv" ]; then
        die "jv $JV_VERSION is not installed at $jv. Install it with scripts/install-jv.sh"
    fi

    out=$("$jv" "$REPO_ROOT/schemas/draft-07-strict.json" "$REPO_ROOT/workstation-config.schema.json" 2>&1) || rc=$?
    case $rc in
        0) ;;
        1)
            echo "$out" >&2
            if grep -q "^schema .*: failed$" <<< "$out"; then
                die "could not load schemas/draft-07-strict.json"
            fi
            if grep -q "additional properties .* not allowed" <<< "$out"; then
                die "workstation-config.schema.json has a keyword that JSON Schema draft-07 does not know (a typo?). jv ignores such keywords, so the rule would not apply"
            fi
            die "could not load workstation-config.schema.json (a missing file, broken JSON, or a schema that breaks the JSON Schema rules)"
            ;;
        *)
            echo "$out" >&2
            die "jv failed with exit code $rc"
            ;;
    esac

    out=$("$jv" "$REPO_ROOT/workstation-config.schema.json" "$CONFIG_FILE" 2>&1) || rc=$?
    case $rc in
        0) log "workstation-config.json matches workstation-config.schema.json" ;;
        1)
            echo "$out" >&2
            if grep -q "^schema .*: failed$" <<< "$out"; then
                die "could not load workstation-config.schema.json (a missing file, broken JSON, or a schema that breaks the JSON Schema rules)"
            fi
            if grep -q "^ *- at '" <<< "$out"; then
                die "workstation-config.json breaks the rules above. The rules and their reasons are in the descriptions of workstation-config.schema.json"
            fi
            die "could not read workstation-config.json (a missing file or broken JSON)"
            ;;
        *)
            echo "$out" >&2
            die "jv failed with exit code $rc"
            ;;
    esac
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
# 選んでいる workspace には "* "、ほかは空白 2 つの字下げ、最後に空行が付く。単語では分けない (* がファイル名に展開される)。
# 一覧を取れなければ (s3:ListBucket が無いなど) 止まる。空の一覧と取り違えると、消すべき人を黙って残すため
user_workspaces() {
    local out
    if ! out=$(tofu -chdir="$(stack_dir workstations)" workspace list); then
        die "could not list the users' workspaces (tofu workspace list failed). Check s3:ListBucket on the state bucket"
    fi
    sed -E 's/^[* ] *//; /^$/d; /^default$/d' <<< "$out"
}

# ユーザーごとの workspace に分ける前の版は、全員の workstations を 1 つの state (この key) に置いていた。
# その state にリソースが残ったまま進むと、全員分をもう 1 組作ろうとして名前が衝突し、データボリュームが二重にできうる。
# init_stack の後に呼ぶ
refuse_leftover_shared_workstations_state() {
    local key count state
    key="$(jq -er '"\(.projectName)/\(.environment)"' "$CONFIG_FILE")/workstations.tfstate"
    count=$(aws s3api list-objects-v2 --region "$STATE_REGION" --bucket "$TF_STATE_BUCKET" --prefix "$key" \
        --query "length(Contents[?Key=='$key'] || \`[]\`)" --output text)
    if [ "$count" -eq 0 ]; then
        return 0
    fi
    state=$(aws s3 cp --region "$STATE_REGION" "s3://$TF_STATE_BUCKET/$key" -)
    count=$(jq -e '[(.resources // [])[] | select(.mode == "managed")] | length' <<< "$state")
    if [ "$count" -ne 0 ]; then
        die "the state s3://$TF_STATE_BUCKET/$key, used before each user got their own state, still has $count resources. Destroy them with scripts/tofu-destroy.sh of that version, then run this again"
    fi
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

# plan に変更があれば rc=0、無ければ rc=1。読めなければ止まる (条件で呼んでも、exit で止まる)
plan_has_changes() {
    local label=$1 plan_json=$2 rc=0
    jq -e '[(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length > 0' \
        <<< "$plan_json" > /dev/null || rc=$?
    case $rc in
        0 | 1) return "$rc" ;;
        *) die "could not read the $label plan (jq exit $rc)" ;;
    esac
}

# plan の JSON の要約 (作る・変える・作り直す・消すの数と、作り直すアドレス) を出す。読めなければ止まる
print_plan_summary() {
    local label=$1 plan_json=$2
    if ! jq -r --arg label "$label" '
        [(.resource_changes // [])[] | {address, a: (.change.actions | join(","))}] as $c
        | ($c | map(select(.a == "delete,create" or .a == "create,delete"))) as $replace
        | "\($label): create \($c | map(select(.a == "create")) | length), update \($c | map(select(.a == "update")) | length), replace \($replace | length), delete \($c | map(select(.a == "delete")) | length)",
          ($replace[] | "  replace: \(.address)")' <<< "$plan_json" >&2; then
        die "could not summarize the $label plan"
    fi
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

# 1 つの plan を要約し、変更があれば確かめる (変更の無い plan は apply しても何も起きないので確かめない)。
# 変更があれば rc=0、無ければ rc=1 を返す代わりに、変数 PLAN_CHANGED に 1 か 0 を入れる
summarize_plan() {
    if plan_has_changes "$1" "$2"; then
        print_plan_summary "$1" "$2"
        PLAN_CHANGED=1
    else
        log "$1: no changes"
        PLAN_CHANGED=0
    fi
}

confirm_plan() {
    summarize_plan "$1" "$2"
    if [ "$PLAN_CHANGED" -eq 1 ]; then
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

# plan_counts <plan の JSON>: "<作る> <変える> <作り直す> <消す>" の 4 つの数
plan_counts() {
    if ! jq -r '[(.resource_changes // [])[] | .change.actions | join(",")] as $a
        | [($a | map(select(. == "create")) | length), ($a | map(select(. == "update")) | length),
           ($a | map(select(. == "delete,create" or . == "create,delete")) | length), ($a | map(select(. == "delete")) | length)]
        | join(" ")' <<< "$1"; then
        die "could not count the changes in the plan"
    fi
}

# 設定にいる人 (USERS) と、設定から消えたが state が残る人 (REMOVED) を決める。init_stack workstations の後に呼ぶ。
# 一覧を取れなければ止まる (消すべき人を黙って残さない)
find_users() {
    local names name
    USERS=()
    REMOVED=()
    names=$(config_usernames)
    mapfile -t USERS <<< "$names"
    names=$(user_workspaces)
    if [ -n "$names" ]; then
        while IFS= read -r name; do
            if ! in_list "$name" "${USERS[@]}"; then
                REMOVED+=("$name")
            fi
        done <<< "$names"
    fi
    log "users to destroy (removed from workstation-config.json): ${REMOVED[*]:-none}"
}

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

# network の plan を <plan の置き場所>/network.tfplan に保存し、その JSON を NETWORK_PLAN_JSON に入れる。init_stack network の後に呼ぶ
plan_network() {
    local dir
    dir=$(stack_dir network)
    log "network: plan"
    tofu -chdir="$dir" plan -input=false -out="$1/network.tfplan"
    NETWORK_PLAN_JSON=$(tofu -chdir="$dir" show -json "$1/network.tfplan")
    refuse_network_replacement "$NETWORK_PLAN_JSON"
}

# ユーザーの workspace ごとに plan を保存し、要約を出す (1 つでも失敗したら止まる)。init_stack workstations の後に呼ぶ。
# USER_CHANGES に変更のある plan の数、USER_COUNTS[<名前>] に plan_counts の 4 つの数を入れる
#   plan_user_stacks <plan の置き場所> <apply するユーザー...> -- <destroy するユーザー...>
plan_user_stacks() {
    local plan_dir=$1 dir u plan_json
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
    USER_CHANGES=0
    declare -gA USER_COUNTS=()

    # LIMIT: ユーザーを 1 人ずつ順に plan・apply するので、人数に比例して時間がかかる。CI の時間が問題になったら並列にする (state もロックも人ごと)
    for u in "${apply_users[@]}"; do
        log "workstations/$u: plan"
        tofu -chdir="$dir" workspace select -or-create "$u"
        tofu -chdir="$dir" plan -input=false -out="$plan_dir/user-$u.tfplan"
        plan_json=$(tofu -chdir="$dir" show -json "$plan_dir/user-$u.tfplan")
        summarize_plan "workstations/$u" "$plan_json"
        USER_CHANGES=$((USER_CHANGES + PLAN_CHANGED))
        # shellcheck disable=SC2034 # tofu-plan.sh が読む
        USER_COUNTS[$u]=$(plan_counts "$plan_json")
    done
    # data source (AMI の SSM パラメータ・VPC の検索) を読まずに、state にあるものを消す
    for u in "${destroy_users[@]}"; do
        log "workstations/$u: plan -destroy"
        tofu -chdir="$dir" workspace select "$u"
        tofu -chdir="$dir" plan -destroy -refresh=false -input=false -out="$plan_dir/user-$u.tfplan"
        plan_json=$(tofu -chdir="$dir" show -json "$plan_dir/user-$u.tfplan")
        summarize_plan "workstations/$u" "$plan_json"
        USER_CHANGES=$((USER_CHANGES + PLAN_CHANGED))
        # shellcheck disable=SC2034 # tofu-plan.sh が読む
        USER_COUNTS[$u]=$(plan_counts "$plan_json")
    done
}

# plan_user_stacks が保存した plan だけを順に apply し、destroy したユーザーの workspace を消す。init_stack workstations の後に呼ぶ。
# 途中で止まったら、どこまで済んだかと <やり直し方> を出す
#   apply_user_stacks <plan の置き場所> <やり直し方> <apply するユーザー...> -- <destroy するユーザー...>
apply_user_stacks() {
    local plan_dir=$1 retry_hint=$2 dir u i
    local apply_users=() destroy_users=() all=()
    shift 2
    while [ $# -gt 0 ] && [ "$1" != -- ]; do
        apply_users+=("$1")
        shift
    done
    if [ $# -gt 0 ]; then
        shift
    fi
    destroy_users=("$@")
    dir=$(stack_dir workstations)

    all=("${apply_users[@]}" "${destroy_users[@]}")
    for i in "${!all[@]}"; do
        u=${all[$i]}
        log "workstations/$u: apply"
        tofu -chdir="$dir" workspace select "$u"
        if ! tofu -chdir="$dir" apply -input=false "$plan_dir/user-$u.tfplan"; then
            # 途中で止まったとき、どこまで済んだかを出す (後の人は apply していない。消える人の workspace も残っている)
            die "workstations/$u: apply failed. Applied: ${all[*]:0:i}. Not applied: ${all[*]:i+1}. Workspaces of removed users are kept: ${destroy_users[*]}. $retry_hint"
        fi
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

# ユーザーの workspace ごとに plan を保存し (1 つでも失敗したら何も apply しない)、要約を出して確かめ、全部を apply する。
# destroy したユーザーの workspace は、apply の後に消す。init_stack workstations の後に呼ぶ
#   apply_user_plans <plan の置き場所> <apply するユーザー...> -- <destroy するユーザー...>
apply_user_plans() {
    local plan_dir=$1
    shift
    plan_user_stacks "$plan_dir" "$@"
    if [ "$USER_CHANGES" -gt 0 ]; then
        confirm_apply workstations
    fi
    apply_user_stacks "$plan_dir" "Fix the cause and run this again" "$@"
}

# approval_text <要約>: CodePipeline の承認の画面に出す 1 行 ("commit <12 文字> / build <ビルドの ID> / <要約>")。
# 承認の CustomData の上限 (500 文字) に収まるよう、要約を切って印を付ける
approval_text() {
    local summary=$1 commit build prefix marker=" ... (truncated, see the build log)" max=500 room
    commit=${CODEBUILD_RESOLVED_SOURCE_VERSION:-$(git -C "$REPO_ROOT" rev-parse HEAD 2> /dev/null || echo unknown)}
    build=${CODEBUILD_BUILD_ID:-local}
    prefix="commit ${commit:0:12} / build ${build##*:} / "
    if [ $((${#prefix} + ${#summary})) -le "$max" ]; then
        echo "$prefix$summary"
        return 0
    fi
    room=$((max - ${#prefix} - ${#marker}))
    echo "$prefix${summary:0:room}$marker"
}

# write_pipeline_vars <置き場所> <true|false> <要約>: CodePipeline の変数 (CHANGED・SUMMARY・APPROVAL) を <置き場所>/vars に書く。
# CodeBuild の exported-variables は buildspec のシェルの変数しか拾わないので、buildspec がこのファイルを読んで export する
write_pipeline_vars() {
    mkdir -p "$1/vars"
    echo "$2" > "$1/vars/changed"
    echo "$3" > "$1/vars/summary"
    approval_text "$3" > "$1/vars/approval"
}
