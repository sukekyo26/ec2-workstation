#!/usr/bin/env bash
# scripts/tofu-deploy.sh・scripts/tofu-destroy.sh・scripts/tofu-init.sh の順番と止まり方を、偽の tofu・aws で確かめる。
# - スクリプトは一時ディレクトリのリポジトリの形 (scripts/・opentofu/stacks/・workstation-config.json) に写して走らせ、
#   設定はテストが用意したものを読ませる (リポジトリの workstation-config.json の値に頼らない)
# - 偽の tofu・aws は一時ディレクトリに実行できるファイルとして置き、PATH の先頭に足す
#   (シェルの関数は子プロセスに届かないため)
# - 偽の tofu は、workstations の workspace (一覧と選んでいるもの) を覚え、本物と同じ書式で一覧を返し、
#   選んだままの workspace の delete を断り、plan を取った workspace と違う所での apply を断る
#
#   scripts/tests/tofu-deploy.test.sh
set -euo pipefail

scripts_src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

repo="$work/repo"
mkdir -p "$repo/opentofu/stacks/network" "$repo/opentofu/stacks/workstations" "$work/bin" "$work/out"
cp -R "$scripts_src" "$repo/scripts"
echo '{"projectName": "testproj", "environment": "staging", "users": [{"username": "developer1"}, {"username": "developer2"}]}' > "$repo/workstation-config.json"
cp "$scripts_src/../workstation-config.schema.json" "$repo/"

cat > "$work/bin/tofu" << 'FAKE'
#!/usr/bin/env bash
# 偽の tofu: 呼ばれたコマンドを "<stack>[@<選んでいる workspace>] <args>" で $FAKE_LOG に 1 行ずつ書く。
# plan のファイルはパスを落として名前だけ書く。workspace の状態は $FAKE_STATE に置く
set -euo pipefail
stack=$(basename "${1#-chdir=}")
shift
selected_file="$FAKE_STATE/$stack.selected"
workspaces_file="$FAKE_STATE/$stack.workspaces"
selected=$(cat "$selected_file" 2> /dev/null || echo default)
where=$stack
if [ "$stack" = workstations ]; then
    where="$stack@$selected"
fi
args=()
for a in "$@"; do
    case "$a" in
        -out=*) args+=("-out=$(basename "${a#-out=}")") ;;
        *.tfplan) args+=("$(basename "$a")") ;;
        *) args+=("$a") ;;
    esac
done
echo "$where ${args[*]}" >> "$FAKE_LOG"

has_workspace() {
    grep -qxF -- "$1" "$workspaces_file" 2> /dev/null
}

case "$1" in
    init)
        # スクリプトは init の前に .terraform/environment を消すので、選択は default に戻る
        echo default > "$selected_file"
        ;;
    workspace)
        case "$2" in
            list)
                if [ "${FAKE_LIST_FAIL:-}" = 1 ]; then
                    exit 1
                fi
                # 本物と同じ書式: 選んでいるものに "* "、ほかは空白 2 つ、最後に空行。FAKE_LIST_SELECTED で印の位置を変えられる
                mark=${FAKE_LIST_SELECTED:-$selected}
                for w in default $(cat "$workspaces_file" 2> /dev/null); do
                    if [ "$w" = "$mark" ]; then echo "* $w"; else echo "  $w"; fi
                done
                echo
                ;;
            select)
                if [ "$3" = -or-create ]; then
                    name=$4
                    if [ "$name" != default ] && ! has_workspace "$name"; then
                        echo "$name" >> "$workspaces_file"
                    fi
                else
                    name=$3
                    if [ "$name" != default ] && ! has_workspace "$name"; then
                        echo "fake tofu: workspace $name does not exist" >&2
                        exit 1
                    fi
                fi
                echo "$name" > "$selected_file"
                ;;
            delete)
                if [ "$3" = "$selected" ]; then
                    echo "fake tofu: cannot delete the currently selected workspace $3" >&2
                    exit 1
                fi
                grep -vxF -- "$3" "$workspaces_file" > "$workspaces_file.new" || true
                mv "$workspaces_file.new" "$workspaces_file"
                ;;
            *) exit 1 ;;
        esac
        ;;
    console)
        echo '"{\"aws_region\":\"us-west-2\",\"vpc_name\":\"testproj-staging-vpc\"}"'
        ;;
    show)
        if [ $# -eq 2 ]; then
            # show -json だけなら state
            if [ "${FAKE_NETWORK_STATE_EMPTY:-}" = 1 ]; then
                echo '{"format_version":"1.0"}'
            else
                echo '{"format_version":"1.0","values":{"root_module":{"child_modules":[{"resources":[{"address":"module.network.aws_vpc.this","mode":"managed","type":"aws_vpc"}]}]}}}'
            fi
        else
            # FAKE_SHOW_PLAN_<stack>_<workspace>、無ければ FAKE_SHOW_PLAN_<stack>
            var="FAKE_SHOW_PLAN_${stack}_$selected"
            if [ -z "${!var:-}" ]; then
                var="FAKE_SHOW_PLAN_$stack"
            fi
            if [ "${!var:-}" = fail ]; then
                exit 1
            fi
            no_change='{"resource_changes":[{"address":"x","type":"aws_vpc","change":{"actions":["no-op"]}}]}'
            echo "${!var:-$no_change}"
        fi
        ;;
    plan)
        if [ "${FAKE_PLAN_FAIL:-}" = "$where" ]; then
            exit 1
        fi
        for a in "$@"; do
            case "$a" in -out=*) echo "$where" > "${a#-out=}" ;; esac
        done
        ;;
    apply)
        if [ "${FAKE_APPLY_FAIL:-}" = "$where" ]; then
            exit 1
        fi
        # 保存した plan だけを、その plan を取ったルート・workspace で apply する
        planfile=${*: -1}
        if [ ! -f "$planfile" ] || [ "$(cat "$planfile")" != "$where" ]; then
            echo "fake tofu: apply in $where needs a plan file saved by plan in $where: $planfile" >&2
            exit 1
        fi
        ;;
    *)
        echo "fake tofu: unexpected command: $*" >&2
        exit 1
        ;;
esac
FAKE

cat > "$work/bin/aws" << 'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "aws $*" >> "$FAKE_LOG"
case "$1 $2" in
    "ec2 describe-vpcs") echo "${FAKE_VPC_COUNT:-0}" ;;
    # ユーザーごとに分ける前の版の state (FAKE_LEGACY_STATE に中身。空なら無い)
    "s3api list-objects-v2") if [ -n "${FAKE_LEGACY_STATE:-}" ]; then echo 1; else echo 0; fi ;;
    "s3 cp") echo "$FAKE_LEGACY_STATE" ;;
    *)
        echo "fake aws: unexpected command: $*" >&2
        exit 1
        ;;
esac
FAKE
chmod +x "$work/bin/tofu" "$work/bin/aws"

# 偽の jv は、スクリプトが探す写しの .tools/jv-<版>/jv に置く。FAKE_JV で答えを変える (既定は通す)
jv=$(bash -c '. "$1/scripts/lib/tofu-common.sh"; jv_path' _ "$repo")
mkdir -p "$(dirname "$jv")"
cat > "$jv" << 'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# どのディレクトリから呼ばれても同じファイルを読むよう、引数は写しの中の実在するファイルの絶対パスでなければならない
for a in "$@"; do
    case "$a" in
        "$FAKE_REPO"/*) ;;
        *) echo "fake jv: not an absolute path under the repository: $a" && exit 2 ;;
    esac
    if [ ! -f "$a" ]; then
        echo "fake jv: no such file: $a"
        exit 2
    fi
done
case "${FAKE_JV:-ok}" in
    ok) echo "instance $2: ok" ;;
    violation)
        printf '%s\n' "instance $2: failed" "- at '/autoStopConfig/cpuEvaluationMinutes': maximum: got 180, want 60"
        exit 1
        ;;
    unreadable)
        printf '%s\n' "instance $2: failed" "unexpected EOF"
        exit 1
        ;;
    crash) exit 3 ;;
esac
FAKE
chmod +x "$jv"
export FAKE_REPO="$repo"
# スクリプトは写しの外のディレクトリから呼ぶ (jv に渡すパスが今いるディレクトリに頼らないことを見る)
cd "$work"

export PATH="$work/bin:$PATH"
if [ "$(command -v tofu)" != "$work/bin/tofu" ] || [ "$(command -v aws)" != "$work/bin/aws" ]; then
    echo "the fake tofu or aws is not first on PATH" >&2
    exit 1
fi

failures=0

# run <name> <script> <stdin> [VAR=value ... | arg ...]: 偽の環境でスクリプトを走らせ、rc・ログ・標準エラーを残す。
# = を含むものは環境変数、ほかはスクリプトの引数。端末でない形で走らせ (EC2WS_ASSUME_TERMINAL=no)、端末のふりは引数で上書きする。
# workstations の workspace は FAKE_WORKSPACES (空白区切り。既定は設定の 2 人) で始める
run() {
    local name=$1 script=$2 input=$3 a w
    shift 3
    local vars=() args=() workspaces="developer1 developer2"
    for a in "$@"; do
        case "$a" in
            FAKE_WORKSPACES=*) workspaces=${a#FAKE_WORKSPACES=} ;;
            *=*) vars+=("$a") ;;
            *) args+=("$a") ;;
        esac
    done
    export FAKE_LOG="$work/out/$name.log" FAKE_STATE="$work/out/$name.state"
    : > "$FAKE_LOG"
    rm -rf "$FAKE_STATE"
    mkdir "$FAKE_STATE"
    : > "$FAKE_STATE/workstations.workspaces"
    for w in $workspaces; do
        echo "$w" >> "$FAKE_STATE/workstations.workspaces"
    done
    local rc=0
    printf '%s' "$input" | env TF_STATE_BUCKET=test-bucket EC2WS_ASSUME_TERMINAL=no "${vars[@]}" \
        "$repo/scripts/$script" "${args[@]}" > /dev/null 2> "$work/out/$name.err" || rc=$?
    echo "$rc" > "$work/out/$name.rc"
}

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

expect_rc() {
    local name=$1 want=$2 got
    got=$(cat "$work/out/$name.rc")
    if [ "$got" != "$want" ]; then
        fail "$name: exit code $got, want $want"
        sed 's/^/    /' "$work/out/$name.err" >&2
    fi
}

expect_log() {
    local name=$1 want=$2
    # 空の期待は「1 度も呼ばれない」
    if ! diff <(if [ -n "$want" ]; then printf '%s\n' "$want"; fi) "$work/out/$name.log" > "$work/out/$name.diff"; then
        fail "$name: commands differ from the expected ones (- want, + got)"
        sed 's/^/    /' "$work/out/$name.diff" >&2
    fi
}

expect_err() {
    local name=$1 want=$2
    if ! grep -qF -- "$want" "$work/out/$name.err"; then
        fail "$name: stderr does not contain: $want"
        sed 's/^/    /' "$work/out/$name.err" >&2
    fi
}

expect_no_err() {
    local name=$1 unwanted=$2
    if grep -qF -- "$unwanted" "$work/out/$name.err"; then
        fail "$name: stderr contains: $unwanted"
    fi
}

expect_no_log() {
    local name=$1 unwanted=$2
    if grep -qF -- "$unwanted" "$work/out/$name.log"; then
        fail "$name: unexpected command: $(grep -F -- "$unwanted" "$work/out/$name.log" | head -1)"
    fi
}

expect_workspaces() {
    local name=$1 want=$2 got
    got=$(tr '\n' ' ' < "$work/out/$name.state/workstations.workspaces" | sed 's/ $//')
    if [ "$got" != "$want" ]; then
        fail "$name: workspaces left: '$got', want '$want'"
    fi
}

init_network="network init -input=false -reconfigure -backend-config=bucket=test-bucket -backend-config=key=testproj/staging/network.tfstate -backend-config=region=ap-northeast-1"
init_workstations="workstations@default init -input=false -reconfigure -backend-config=bucket=test-bucket -backend-config=key=testproj/staging/workstation.tfstate -backend-config=workspace_key_prefix=testproj/staging/users -backend-config=region=ap-northeast-1"
leftover_check="network show -json
network console
aws ec2 describe-vpcs --region us-west-2 --filters Name=tag:Name,Values=testproj-staging-vpc --query length(Vpcs) --output text"
network_plan="network plan -input=false -out=network.tfplan
network show -json network.tfplan"
network_apply="network apply -input=false network.tfplan"
legacy_check="aws s3api list-objects-v2 --region ap-northeast-1 --bucket test-bucket --prefix testproj/staging/workstations.tfstate --query length(Contents[?Key=='testproj/staging/workstations.tfstate'] || \`[]\`) --output text"
deploy_start="$init_network
network show -json
$legacy_check
$init_workstations
workstations@default workspace list"
users_plan="workstations@default workspace select -or-create developer1
workstations@developer1 plan -input=false -out=user-developer1.tfplan
workstations@developer1 show -json user-developer1.tfplan
workstations@developer1 workspace select -or-create developer2
workstations@developer2 plan -input=false -out=user-developer2.tfplan
workstations@developer2 show -json user-developer2.tfplan"
users_apply="workstations@developer2 workspace select developer1
workstations@developer1 apply -input=false user-developer1.tfplan
workstations@developer1 workspace select developer2
workstations@developer2 apply -input=false user-developer2.tfplan"
creates='{"resource_changes":[{"address":"module.a.aws_vpc.this","type":"aws_vpc","change":{"actions":["create"]}},{"address":"module.a.aws_subnet.public","type":"aws_subnet","change":{"actions":["create"]}}]}'
replaces='{"resource_changes":[{"address":"module.workstation[\"dev1\"].aws_instance.this","type":"aws_instance","change":{"actions":["delete","create"]}},{"address":"module.workstation[\"dev1\"].aws_volume_attachment.data","type":"aws_volume_attachment","change":{"actions":["create","delete"]}},{"address":"module.workstation[\"dev1\"].aws_ebs_volume.data","type":"aws_ebs_volume","change":{"actions":["update"]}}]}'
destroys='{"resource_changes":[{"address":"a","type":"aws_vpc","change":{"actions":["delete"]}}]}'

# --- deploy ---

run deploy tofu-deploy.sh ""
expect_rc deploy 0
expect_log deploy "$deploy_start
$network_plan
$network_apply
$users_plan
$users_apply"
expect_err deploy "users to destroy (removed from workstation-config.json): none"

# 設定から消えたユーザー (state だけが残る workspace) は、ほかの人の plan と一緒に destroy の plan を取り、apply の後に workspace を消す。
# 一覧は本物と同じ書式で、設定にいる developer1 を選んだ印 (* developer1) が付いている
run deploy-removed tofu-deploy.sh "" "FAKE_WORKSPACES=developer1 gone developer2" FAKE_LIST_SELECTED=developer1
expect_rc deploy-removed 0
expect_log deploy-removed "$deploy_start
$network_plan
$network_apply
$users_plan
workstations@developer2 workspace select gone
workstations@gone plan -destroy -refresh=false -input=false -out=user-gone.tfplan
workstations@gone show -json user-gone.tfplan
workstations@gone workspace select developer1
workstations@developer1 apply -input=false user-developer1.tfplan
workstations@developer1 workspace select developer2
workstations@developer2 apply -input=false user-developer2.tfplan
workstations@developer2 workspace select gone
workstations@gone apply -input=false user-gone.tfplan
workstations@gone workspace select default
workstations@default workspace delete gone"
expect_err deploy-removed "users to destroy (removed from workstation-config.json): gone"
expect_workspaces deploy-removed "developer1 developer2"

# 新しいユーザー (workspace がまだ無い) は workspace を作って plan する
run deploy-new-user tofu-deploy.sh "" "FAKE_WORKSPACES=developer1"
expect_rc deploy-new-user 0
expect_workspaces deploy-new-user "developer1 developer2"

# 1 人の plan が失敗したら、ユーザーの workspace では 1 つも apply しない。network の apply はその前に 1 回だけ
for who in developer1 developer2 gone; do
    run "deploy-plan-fails-$who" tofu-deploy.sh "" "FAKE_WORKSPACES=developer1 developer2 gone" "FAKE_PLAN_FAIL=workstations@$who"
    expect_rc "deploy-plan-fails-$who" 1
    expect_no_log "deploy-plan-fails-$who" "workstations@developer1 apply"
    expect_no_log "deploy-plan-fails-$who" "workstations@developer2 apply"
    expect_no_log "deploy-plan-fails-$who" "workstations@gone apply"
    expect_no_log "deploy-plan-fails-$who" "workspace delete"
    if [ "$(grep -c '^network apply' "$work/out/deploy-plan-fails-$who.log")" != 1 ] ||
        [ "$(grep -n '^network apply' "$work/out/deploy-plan-fails-$who.log" | cut -d: -f1)" -gt "$(grep -n 'workstations@.* plan' "$work/out/deploy-plan-fails-$who.log" | head -1 | cut -d: -f1)" ]; then
        fail "deploy-plan-fails-$who: network must be applied exactly once, before the first user plan"
    fi
done

run deploy-network-plan-fails tofu-deploy.sh "" FAKE_PLAN_FAIL=network
expect_rc deploy-network-plan-fails 1
expect_log deploy-network-plan-fails "$deploy_start
network plan -input=false -out=network.tfplan"

# VPC・サブネットの作り直し・削除は apply せずに止まる
for actions in '"delete","create"' '"create","delete"' '"delete"'; do
    for type in aws_vpc aws_subnet; do
        name="deploy-replace-$type-$(tr -dc '[:lower:]' <<< "$actions")"
        run "$name" tofu-deploy.sh "" "FAKE_SHOW_PLAN_network={\"resource_changes\":[{\"address\":\"a\",\"type\":\"aws_flow_log\",\"change\":{\"actions\":[\"update\"]}},{\"address\":\"b\",\"type\":\"$type\",\"change\":{\"actions\":[$actions]}}]}"
        expect_rc "$name" 1
        expect_log "$name" "$deploy_start
$network_plan"
        expect_err "$name" "Run scripts/tofu-destroy.sh first, then scripts/tofu-deploy.sh"
    done
done

# 作る・in-place の変更・resource_changes の無い plan は進む
for plan in "$creates" \
    '{"resource_changes":[{"address":"a","type":"aws_subnet","change":{"actions":["update"]}}]}' \
    '{"format_version":"1.2"}'; do
    run deploy-network-plan-ok tofu-deploy.sh "" "FAKE_SHOW_PLAN_network=$plan"
    expect_rc deploy-network-plan-ok 0
done

# plan を読めなければ apply しない
for target in network workstations_developer2; do
    for show in fail 'not json'; do
        run "deploy-show-broken-$target" tofu-deploy.sh "" "FAKE_SHOW_PLAN_$target=$show"
        expect_rc "deploy-show-broken-$target" 1
        expect_no_log "deploy-show-broken-$target" "workstations@developer1 apply"
        if [ "$target" = network ]; then
            expect_no_log "deploy-show-broken-$target" "network apply"
        fi
    done
done

# network の state が空で、同じ Name の VPC がデプロイ先のリージョンに残っていれば、plan の前に止まる
run deploy-leftover-vpc tofu-deploy.sh "" FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=1
expect_rc deploy-leftover-vpc 1
expect_log deploy-leftover-vpc "$init_network
$leftover_check"
expect_err deploy-leftover-vpc "Destroy it with that version"

# 初めての deploy (state が空で VPC も無い) は進む
run deploy-first tofu-deploy.sh "" FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=0 FAKE_WORKSPACES=
expect_rc deploy-first 0
expect_log deploy-first "$init_network
$leftover_check
$legacy_check
$init_workstations
workstations@default workspace list
$network_plan
$network_apply
$users_plan
$users_apply"

# 端末: 変更のある段ごとに要約を出し、yes で apply する。workstations は全員の plan の後に 1 回だけ聞く
run deploy-terminal-yes tofu-deploy.sh $'yes\nyes\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$creates" "FAKE_SHOW_PLAN_workstations_developer1=$replaces" "FAKE_SHOW_PLAN_workstations_developer2=$creates"
expect_rc deploy-terminal-yes 0
expect_log deploy-terminal-yes "$deploy_start
$network_plan
$network_apply
$users_plan
$users_apply"
expect_err deploy-terminal-yes "network: create 2, update 0, replace 0, delete 0"
expect_err deploy-terminal-yes "workstations/developer1: create 0, update 1, replace 2, delete 0"
expect_err deploy-terminal-yes '  replace: module.workstation["dev1"].aws_instance.this'
expect_err deploy-terminal-yes '  replace: module.workstation["dev1"].aws_volume_attachment.data'
expect_err deploy-terminal-yes "workstations/developer2: create 2, update 0, replace 0, delete 0"
expect_err deploy-terminal-yes 'Apply the workstations plan above? Only "yes" applies'

# 端末: yes 以外なら apply せずに止まる (1 段目で断れば network も apply しない)
for answer in no '' YES y; do
    run deploy-terminal-no tofu-deploy.sh "$answer" EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$creates"
    expect_rc deploy-terminal-no 1
    expect_log deploy-terminal-no "$deploy_start
$network_plan"
    expect_err deploy-terminal-no "network: not applied"
done

# 端末: 2 段目で断れば、どのユーザーも apply せず、消えたユーザーの workspace も消さない
run deploy-terminal-no-workstations tofu-deploy.sh $'yes\nno\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_WORKSPACES=developer1 developer2 gone" "FAKE_SHOW_PLAN_network=$creates" "FAKE_SHOW_PLAN_workstations=$replaces"
expect_rc deploy-terminal-no-workstations 1
expect_no_log deploy-terminal-no-workstations "workstations@developer1 apply"
expect_no_log deploy-terminal-no-workstations "workstations@gone apply"
expect_no_log deploy-terminal-no-workstations "workspace delete"
expect_err deploy-terminal-no-workstations "workstations: not applied"
expect_workspaces deploy-terminal-no-workstations "developer1 developer2 gone"

# 端末: 変更の無い段は確かめない (network は変更なし、workstations だけ確かめる)
run deploy-terminal-no-change tofu-deploy.sh $'yes\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_workstations_developer2=$replaces"
expect_rc deploy-terminal-no-change 0
expect_err deploy-terminal-no-change "network: no changes"
expect_err deploy-terminal-no-change "workstations/developer1: no changes"
expect_no_err deploy-terminal-no-change "Apply the network plan above?"
expect_err deploy-terminal-no-change "Apply the workstations plan above?"

# 端末でなければ、変更があっても確かめずに進む (要約は出す)
run deploy-not-terminal tofu-deploy.sh "" "FAKE_SHOW_PLAN_network=$creates" "FAKE_SHOW_PLAN_workstations=$replaces"
expect_rc deploy-not-terminal 0
expect_err deploy-not-terminal "workstations/developer2: create 0, update 1, replace 2, delete 0"
expect_no_err deploy-not-terminal "Apply the"

# TF_WORKSPACE と TF_STATE_BUCKET の誤りは、tofu を呼ぶ前に止まる
for script in tofu-deploy.sh tofu-destroy.sh tofu-init.sh; do
    args=()
    if [ "$script" = tofu-init.sh ]; then
        args=(network)
    fi
    run "$script-tf-workspace" "$script" "" TF_WORKSPACE=developer1 "${args[@]}"
    expect_rc "$script-tf-workspace" 1
    expect_log "$script-tf-workspace" ""
    expect_err "$script-tf-workspace" "unset TF_WORKSPACE"

    run "$script-no-bucket" "$script" "" TF_STATE_BUCKET= "${args[@]}"
    expect_rc "$script-no-bucket" 1
    expect_log "$script-no-bucket" ""
    expect_err "$script-no-bucket" "set TF_STATE_BUCKET"
done

# workspace の一覧を取れなければ (s3:ListBucket が無いなど)、何も apply しない
for script in tofu-deploy.sh tofu-destroy.sh; do
    run "$script-list-fails" "$script" "" FAKE_LIST_FAIL=1
    expect_rc "$script-list-fails" 1
    expect_no_log "$script-list-fails" "apply"
    expect_err "$script-list-fails" "could not list the users' workspaces"
done

# 要約の jq が失敗したら (actions が配列でない plan)、その段は apply しない
bad_summary='{"resource_changes":[{"address":"a","type":"aws_instance","change":{"actions":"create"}}]}'
run deploy-summary-fails-network tofu-deploy.sh "" "FAKE_SHOW_PLAN_network=$bad_summary"
expect_rc deploy-summary-fails-network 1
expect_no_log deploy-summary-fails-network "apply"
run deploy-summary-fails-user tofu-deploy.sh "" "FAKE_SHOW_PLAN_workstations_developer2=$bad_summary"
expect_rc deploy-summary-fails-user 1
expect_no_log deploy-summary-fails-user "workstations@developer1 apply"
run destroy-summary-fails tofu-destroy.sh "" "FAKE_SHOW_PLAN_workstations=$bad_summary"
expect_rc destroy-summary-fails 1
expect_no_log destroy-summary-fails "apply"

# ユーザーごとに分ける前の版の state にリソースが残っていれば、何もせずに止まる。残っていなければ (destroy の後の空の state) 進む
for script in tofu-deploy.sh tofu-destroy.sh; do
    run "$script-legacy-state" "$script" "" 'FAKE_LEGACY_STATE={"version":4,"resources":[{"mode":"data","type":"aws_vpc"},{"mode":"managed","type":"aws_instance"}]}'
    expect_rc "$script-legacy-state" 1
    expect_log "$script-legacy-state" "$init_network
network show -json
$legacy_check
aws s3 cp --region ap-northeast-1 s3://test-bucket/testproj/staging/workstations.tfstate -"
    expect_err "$script-legacy-state" "still has 1 resources. Destroy them with scripts/tofu-destroy.sh of that version"

    run "$script-legacy-state-empty" "$script" "" 'FAKE_LEGACY_STATE={"version":4,"resources":[]}'
    expect_rc "$script-legacy-state-empty" 0
done

# apply の途中で 1 人が失敗したら、そこで止まり、どこまで済んだかを出す (後の人と、消える人の destroy は走らない)
run deploy-apply-fails tofu-deploy.sh "" "FAKE_WORKSPACES=developer1 developer2 gone" FAKE_APPLY_FAIL=workstations@developer2
expect_rc deploy-apply-fails 1
expect_no_log deploy-apply-fails "workstations@gone apply"
expect_no_log deploy-apply-fails "workspace delete"
expect_err deploy-apply-fails "workstations/developer2: apply failed. Applied: developer1. Not applied: gone. Workspaces of removed users are kept: gone."
expect_workspaces deploy-apply-fails "developer1 developer2 gone"

# --- init ---

run init-network tofu-init.sh "" network
expect_rc init-network 0
expect_log init-network "$init_network"

# 設定にいるユーザーの workspace を選ぶ (無ければ作る)
run init-user tofu-init.sh "" workstations developer2 FAKE_WORKSPACES=developer1
expect_rc init-user 0
expect_log init-user "$init_workstations
workstations@default workspace list
workstations@default workspace select -or-create developer2"

# 設定から消えたが state のあるユーザーも選べる (手で destroy するため)
run init-removed-user tofu-init.sh "" workstations gone "FAKE_WORKSPACES=developer1 gone"
expect_rc init-removed-user 0
expect_no_err init-removed-user "ERROR"

# 設定にも state にも無い名前 (打ち間違い) では、workspace を作らずに止まる
run init-typo tofu-init.sh "" workstations developr1
expect_rc init-typo 1
expect_err init-typo "developr1 is not a username in workstation-config.json and has no state"
expect_no_log init-typo "workspace select"

for args in "" "workstations" "network x" "workstations a b" "other"; do
    # shellcheck disable=SC2086 # 引数を空白で分けて渡す
    run init-usage tofu-init.sh "" $args
    expect_rc init-usage 1
    expect_log init-usage ""
    expect_err init-usage "usage:"
done

# --- destroy ---

# 設定でなく、state を持つ全員 (設定から消えた gone も) を消し、workspace を消してから network
run destroy tofu-destroy.sh "" "FAKE_WORKSPACES=developer1 gone" "FAKE_SHOW_PLAN_network=$destroys" "FAKE_SHOW_PLAN_workstations=$destroys"
expect_rc destroy 0
expect_log destroy "$init_network
network show -json
$legacy_check
$init_workstations
workstations@default workspace list
workstations@default workspace select developer1
workstations@developer1 plan -destroy -refresh=false -input=false -out=user-developer1.tfplan
workstations@developer1 show -json user-developer1.tfplan
workstations@developer1 workspace select gone
workstations@gone plan -destroy -refresh=false -input=false -out=user-gone.tfplan
workstations@gone show -json user-gone.tfplan
workstations@gone workspace select developer1
workstations@developer1 apply -input=false user-developer1.tfplan
workstations@developer1 workspace select gone
workstations@gone apply -input=false user-gone.tfplan
workstations@gone workspace select default
workstations@default workspace delete developer1
workstations@default workspace delete gone
network plan -destroy -refresh=false -input=false -out=network.tfplan
network show -json network.tfplan
$network_apply"
expect_workspaces destroy ""

# ユーザーの state が無ければ、network だけを消す
run destroy-no-users tofu-destroy.sh "" FAKE_WORKSPACES=
expect_rc destroy-no-users 0
expect_log destroy-no-users "$init_network
network show -json
$legacy_check
$init_workstations
workstations@default workspace list
network plan -destroy -refresh=false -input=false -out=network.tfplan
network show -json network.tfplan
$network_apply"

# 前の形の環境が残っていれば、何も消さずに止まる (新しい state を消して「成功」しない)
run destroy-leftover-vpc tofu-destroy.sh "" FAKE_NETWORK_STATE_EMPTY=1 FAKE_VPC_COUNT=1
expect_rc destroy-leftover-vpc 1
expect_log destroy-leftover-vpc "$init_network
$leftover_check"
expect_err destroy-leftover-vpc "Destroy it with that version"

# 1 人でも消せなければ、誰も apply せず、network に進まない
run destroy-user-fails tofu-destroy.sh "" FAKE_PLAN_FAIL=workstations@developer2
expect_rc destroy-user-fails 1
expect_no_log destroy-user-fails "apply"
expect_no_log destroy-user-fails "network plan"

# plan を読めなければ apply しない
run destroy-show-fails tofu-destroy.sh "" FAKE_SHOW_PLAN_workstations=fail
expect_rc destroy-show-fails 1
expect_no_log destroy-show-fails "apply"

# 端末: 段ごとに yes を待つ。2 段目 (network) で断れば network は消さない
run destroy-terminal tofu-destroy.sh $'yes\nno\n' EC2WS_ASSUME_TERMINAL=yes "FAKE_SHOW_PLAN_network=$destroys" "FAKE_SHOW_PLAN_workstations=$destroys"
expect_rc destroy-terminal 1
expect_no_log destroy-terminal "network apply"
expect_err destroy-terminal "workstations/developer1: create 0, update 0, replace 0, delete 1"
expect_err destroy-terminal "network: create 0, update 0, replace 0, delete 1"
expect_err destroy-terminal "network: not applied"
expect_workspaces destroy-terminal ""

# --- 設定の検証 ---

# deploy・init は、設定の違反・読めない設定・jv の誤りで、tofu を 1 度も呼ばずに止まる。違反と読めないものは案内を分ける
for case in "deploy tofu-deploy.sh" "init-network tofu-init.sh network" "init-user tofu-init.sh workstations developer1"; do
    read -r name script args <<< "$case"
    # shellcheck disable=SC2086 # 引数を空白で分けて渡す
    run "$name-violation" "$script" "" FAKE_JV=violation $args
    expect_rc "$name-violation" 1
    expect_log "$name-violation" ""
    expect_err "$name-violation" "- at '/autoStopConfig/cpuEvaluationMinutes': maximum: got 180, want 60"
    expect_err "$name-violation" "workstation-config.json breaks the rules above"

    # shellcheck disable=SC2086
    run "$name-unreadable" "$script" "" FAKE_JV=unreadable $args
    expect_rc "$name-unreadable" 1
    expect_log "$name-unreadable" ""
    expect_err "$name-unreadable" "could not read workstation-config.json or workstation-config.schema.json"
    expect_no_err "$name-unreadable" "breaks the rules"

    # shellcheck disable=SC2086
    run "$name-jv-crash" "$script" "" FAKE_JV=crash $args
    expect_rc "$name-jv-crash" 1
    expect_log "$name-jv-crash" ""
    expect_err "$name-jv-crash" "jv failed with exit code 3"
done

# jv が無ければ、入れ方を出して止まる (黙って検証を飛ばさない)
mv "$jv" "$jv.off"
run deploy-no-jv tofu-deploy.sh ""
mv "$jv.off" "$jv"
expect_rc deploy-no-jv 1
expect_log deploy-no-jv ""
expect_err deploy-no-jv "Install it with scripts/install-jv.sh"

# destroy は設定を検証しない (設定の違反があっても全部を消せる)
run destroy-violation tofu-destroy.sh "" FAKE_JV=violation
expect_rc destroy-violation 0

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
