#!/usr/bin/env bash
# scripts/check-permissions-boundary.sh を、リポジトリの写しを 1 か所ずつ壊して確かめる。
# - 写しは一時ディレクトリに、検査が読むファイル (boundary・codepipeline.yaml・opentofu/modules) とスクリプトを置く
# - 壊した写しでは終了コード 1 で、Error の行が文の全体で期待どおりであること (1 つ落ちても残りを続ける)
#
#   scripts/tests/check-permissions-boundary.test.sh
set -euo pipefail

repo_src=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

# copy <名前>: 写しを作り、その場所を出す
copy() {
    local dir="$work/$1"
    mkdir -p "$dir/scripts" "$dir/cloudformation" "$dir/opentofu"
    cp "$repo_src/scripts/check-permissions-boundary.sh" "$dir/scripts/" 2> /dev/null || true
    cp "$repo_src/cloudformation/permissions-boundary.yaml" "$repo_src/cloudformation/codepipeline.yaml" "$dir/cloudformation/" 2> /dev/null || true
    cp -R "$repo_src/opentofu/modules" "$dir/opentofu/"
    echo "$dir"
}

# expect <名前> <写し> <rc> [Error の行]: 検査の終了コードと、stderr の Error の行 (無いか、ちょうどこれら)
expect() {
    local name=$1 dir=$2 want_rc=$3 want_line=${4:-} rc=0 errors
    bash "$dir/scripts/check-permissions-boundary.sh" > "$work/$name.out" 2> "$work/$name.err" || rc=$?
    if [ "$rc" != "$want_rc" ]; then
        fail "$name: exit code $rc, want $want_rc"
        sed 's/^/    /' "$work/$name.err" >&2 || true
    fi
    errors=$(grep '^Error: ' "$work/$name.err" || true)
    if [ "$errors" != "$want_line" ]; then
        fail "$name: Error lines differ (- want, + got)"
        diff <(printf '%s\n' "$want_line") <(printf '%s\n' "$errors") | sed 's/^/    /' >&2 || true
    fi
}

boundary=cloudformation/permissions-boundary.yaml

dir=$(copy repo)
expect repo "$dir" 0

dir=$(copy missing-action)
sed -i '/^[[:space:]]*- ec2:StopInstances[[:space:]]*$/d' "$dir/$boundary"
expect missing-action "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf: ec2:StopInstances is not in $boundary"

dir=$(copy new-module-action)
sed -i '0,/"logs:PutLogEvents",/s//"logs:PutLogEvents",\n      "s3:GetObject",/' "$dir/opentofu/modules/workstation/iam.tf"
expect new-module-action "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf: s3:GetObject is not in $boundary"

dir=$(copy renamed)
sed -i 's/-permissions-boundary/-permissions-boundary2/g' "$dir/cloudformation/codepipeline.yaml"
expect renamed "$dir" 1 \
    "Error: the permissions boundary names differ: $boundary 'permissions-boundary', cloudformation/codepipeline.yaml 'permissions-boundary2', opentofu/modules/config/main.tf 'permissions-boundary'"

dir=$(copy missing-sid)
sed -i '/^[[:space:]]*- Sid: AmazonSSMManagedInstanceCore[[:space:]]*$/s/- Sid: AmazonSSMManagedInstanceCore/- Sid: Other/' "$dir/$boundary"
expect missing-sid "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf: the managed policy AmazonSSMManagedInstanceCore has no statement with Sid: AmazonSSMManagedInstanceCore in $boundary"

dir=$(copy inline-jsonencode)
sed -i 's/policy = data\.aws_iam_policy_document\.session_logs_write\.json/policy = jsonencode({ Statement = [] })/' "$dir/opentofu/modules/workstation/iam.tf"
line=$(grep -n 'policy = jsonencode' "$dir/opentofu/modules/workstation/iam.tf" | cut -d: -f1)
expect inline-jsonencode "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf:$line: the policy of aws_iam_role_policy is not data.aws_iam_policy_document.<name>.json (the check reads Actions only from policy documents)"

# 名前は、3 か所のどれか 1 つがずれても落ちる
dir=$(copy renamed-config)
sed -i 's/-permissions-boundary"/-permissions-boundary2"/' "$dir/opentofu/modules/config/main.tf"
expect renamed-config "$dir" 1 \
    "Error: the permissions boundary names differ: $boundary 'permissions-boundary', cloudformation/codepipeline.yaml 'permissions-boundary', opentofu/modules/config/main.tf 'permissions-boundary2'"

dir=$(copy renamed-template)
sed -i 's/^\([[:space:]]*ManagedPolicyName: .*-permissions-boundary\)$/\12/' "$dir/$boundary"
expect renamed-template "$dir" 1 \
    "Error: the permissions boundary names differ: $boundary 'permissions-boundary2', cloudformation/codepipeline.yaml 'permissions-boundary', opentofu/modules/config/main.tf 'permissions-boundary'"

dir=$(copy renamed-one)
sed -i '0,/-permissions-boundary$/s//-permissions-boundary2/' "$dir/cloudformation/codepipeline.yaml"
expect renamed-one "$dir" 1 \
    "Error: the permissions boundary names differ: $boundary 'permissions-boundary', cloudformation/codepipeline.yaml 'permissions-boundary permissions-boundary2', opentofu/modules/config/main.tf 'permissions-boundary'"

# boundary の無いロール
dir=$(copy no-boundary)
sed -i '/^[[:space:]]*permissions_boundary[[:space:]]*=/d' "$dir/opentofu/modules/workstation/autostop.tf"
line=$(grep -n '^resource "aws_iam_role" "scheduler"' "$dir/opentofu/modules/workstation/autostop.tf" | cut -d: -f1)
expect no-boundary "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf:$line: aws_iam_role.scheduler has no permissions_boundary"

# 読めない管理ポリシーの ARN (パス付き)
dir=$(copy managed-path)
sed -i 's|policy/AmazonSSMManagedInstanceCore"|policy/service-role/AmazonSSMManagedInstanceCore"|' "$dir/opentofu/modules/workstation/iam.tf"
line=$(grep -n 'policy/service-role/' "$dir/opentofu/modules/workstation/iam.tf" | cut -d: -f1)
expect managed-path "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf:$line: the policy_arn of aws_iam_role_policy_attachment is not \"arn:aws:iam::aws:policy/<name>\" (the check cannot read it)"

# 検査が読まない付け方: 信頼ポリシーの文書を指す aws_iam_role_policy、aws_iam_policy、managed_policy_arns
dir=$(copy policy-assume)
sed -i 's/policy = data\.aws_iam_policy_document\.session_logs_write\.json/policy = data.aws_iam_policy_document.instance_assume.json/' "$dir/opentofu/modules/workstation/iam.tf"
line=$(grep -n 'policy = data.aws_iam_policy_document.instance_assume.json' "$dir/opentofu/modules/workstation/iam.tf" | cut -d: -f1)
expect policy-assume "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf:$line: the policy of aws_iam_role_policy is data.aws_iam_policy_document.instance_assume, which the check skips as a trust policy (*_assume)"

dir=$(copy iam-policy)
printf '\nresource "aws_iam_policy" "extra" {\n  policy = "{}"\n}\n' >> "$dir/opentofu/modules/workstation/iam.tf"
line=$(grep -n '^resource "aws_iam_policy" "extra"' "$dir/opentofu/modules/workstation/iam.tf" | cut -d: -f1)
expect iam-policy "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf:$line: resource \"aws_iam_policy\" is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)"

dir=$(copy managed-policy-arns)
sed -i 's/^\([[:space:]]*permissions_boundary = local.permissions_boundary_arn\)$/\1\n  managed_policy_arns  = []/' "$dir/opentofu/modules/workstation/autostop.tf"
line=$(grep -n 'managed_policy_arns' "$dir/opentofu/modules/workstation/autostop.tf" | cut -d: -f1)
expect managed-policy-arns "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf:$line: managed_policy_arns of aws_iam_role is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)"

dir=$(copy inline-policy)
sed -i 's/^\([[:space:]]*permissions_boundary = local.permissions_boundary_arn\)$/\1\n  inline_policy {}/' "$dir/opentofu/modules/workstation/autostop.tf"
line=$(grep -n 'inline_policy {}' "$dir/opentofu/modules/workstation/autostop.tf" | cut -d: -f1)
expect inline-policy "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf:$line: inline_policy of aws_iam_role is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)"

# actions の書き方が変わって 1 つも読めないときは、黙って通らずに落ちる
dir=$(copy unreadable)
sed -i -E 's/^([[:space:]]*)actions([[:space:]]*=)/\1action_list\2/' "$dir"/opentofu/modules/*/*.tf
expect unreadable "$dir" 1 \
    "Error: no action found in the aws_iam_policy_document blocks of opentofu/modules"

# boundary の Action を 1 行に 1 つで書かないと (引用符つきも)、読めないことを先に言い、モジュールの Action も全部挙げる
dir=$(copy quoted)
sed -i -E 's/^([[:space:]]*- )([a-z0-9-]+:[A-Za-z0-9*]+)[[:space:]]*$/\1"\2"/' "$dir/$boundary"
expect quoted "$dir" 1 "$(
    echo "Error: no action found in $boundary (one per line: - <service>:<action>)"
    for a in network/main.tf:logs:CreateLogStream network/main.tf:logs:PutLogEvents workstation/autostop.tf:ec2:StopInstances \
        workstation/iam.tf:logs:CreateLogStream workstation/iam.tf:logs:PutLogEvents; do
        echo "Error: opentofu/modules/${a%%:*}: ${a#*:} is not in $boundary"
    done
)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
