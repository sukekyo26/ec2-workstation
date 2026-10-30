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

# must_grep <名前> <パターン> <ファイル>: 置き換えが当たった行の番号を line に入れる。当たらなければ、ケースが空振りしないよう数える
must_grep() {
    line=$(grep -n -m1 -- "$2" "$3" | cut -d: -f1 || true)
    [ -n "$line" ] || fail "$1: the edit did not apply ($2 is not in ${3#"$work/"})"
}

boundary=cloudformation/permissions-boundary.yaml

dir=$(copy repo)
expect repo "$dir" 0

dir=$(copy missing-action)
sed -i '/^[[:space:]]*- ec2:StopInstances[[:space:]]*$/d' "$dir/$boundary"
expect missing-action "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf: ec2:StopInstances is not in $boundary"

dir=$(copy new-module-action)
sed -i '0,/"logs:PutLogEvents",/s//"logs:PutLogEvents",\n      "s3:GetObject",/' "$dir/opentofu/modules/network/main.tf"
must_grep new-module-action '"s3:GetObject",' "$dir/opentofu/modules/network/main.tf"
expect new-module-action "$dir" 1 \
    "Error: opentofu/modules/network/main.tf: s3:GetObject is not in $boundary"

dir=$(copy renamed)
sed -i 's/-permissions-boundary/-permissions-boundary2/g' "$dir/cloudformation/codepipeline.yaml"
expect renamed "$dir" 1 \
    "Error: the permissions boundary names differ: $boundary 'permissions-boundary', cloudformation/codepipeline.yaml 'permissions-boundary2', opentofu/modules/config/main.tf 'permissions-boundary'"

dir=$(copy missing-sid)
sed -i '/^[[:space:]]*- Sid: AmazonSSMManagedInstanceCore[[:space:]]*$/s/- Sid: AmazonSSMManagedInstanceCore/- Sid: Other/' "$dir/$boundary"
expect missing-sid "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf: the managed policy AmazonSSMManagedInstanceCore has no statement with Sid: AmazonSSMManagedInstanceCore in $boundary"

dir=$(copy inline-jsonencode)
sed -i 's/policy = data\.aws_iam_policy_document\.flow_logs_write\.json/policy = jsonencode({ Statement = [] })/' "$dir/opentofu/modules/network/main.tf"
must_grep inline-jsonencode 'policy = jsonencode' "$dir/opentofu/modules/network/main.tf"
expect inline-jsonencode "$dir" 1 \
    "Error: opentofu/modules/network/main.tf:$line: the policy of aws_iam_role_policy is not data.aws_iam_policy_document.<name>.json (the check reads Actions only from policy documents)"

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
if awk '/^resource "aws_iam_role" "scheduler"/,/^}/' "$dir/opentofu/modules/workstation/autostop.tf" | grep -q permissions_boundary; then
    fail "no-boundary: the edit did not apply (aws_iam_role.scheduler still has permissions_boundary)"
fi
must_grep no-boundary '^resource "aws_iam_role" "scheduler"' "$dir/opentofu/modules/workstation/autostop.tf"
expect no-boundary "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf:$line: aws_iam_role.scheduler has no permissions_boundary"

# 読めない管理ポリシーの ARN (パス付き)
dir=$(copy managed-path)
sed -i 's|policy/AmazonSSMManagedInstanceCore"|policy/service-role/AmazonSSMManagedInstanceCore"|' "$dir/opentofu/modules/workstation/iam.tf"
must_grep managed-path 'policy/service-role/' "$dir/opentofu/modules/workstation/iam.tf"
expect managed-path "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf:$line: the policy_arn of aws_iam_role_policy_attachment is not \"arn:aws:iam::aws:policy/<name>\" (the check cannot read it)"

# 検査が読まない付け方: 信頼ポリシーの文書を指す aws_iam_role_policy、aws_iam_policy、managed_policy_arns
dir=$(copy policy-assume)
sed -i 's/policy = data\.aws_iam_policy_document\.flow_logs_write\.json/policy = data.aws_iam_policy_document.flow_logs_assume.json/' "$dir/opentofu/modules/network/main.tf"
must_grep policy-assume 'policy = data.aws_iam_policy_document.flow_logs_assume.json' "$dir/opentofu/modules/network/main.tf"
expect policy-assume "$dir" 1 \
    "Error: opentofu/modules/network/main.tf:$line: the policy of aws_iam_role_policy is data.aws_iam_policy_document.flow_logs_assume, which the check skips as a trust policy (*_assume)"

dir=$(copy iam-policy)
printf '\nresource "aws_iam_policy" "extra" {\n  policy = "{}"\n}\n' >> "$dir/opentofu/modules/workstation/iam.tf"
if [ "$(grep -c '^resource "aws_iam_policy" "extra"' "$dir/opentofu/modules/workstation/iam.tf")" != 1 ]; then
    fail "iam-policy: the edit did not apply (want one resource \"aws_iam_policy\" \"extra\")"
fi
must_grep iam-policy '^resource "aws_iam_policy" "extra"' "$dir/opentofu/modules/workstation/iam.tf"
expect iam-policy "$dir" 1 \
    "Error: opentofu/modules/workstation/iam.tf:$line: resource \"aws_iam_policy\" is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)"

dir=$(copy managed-policy-arns)
sed -i 's/^\([[:space:]]*permissions_boundary = local.permissions_boundary_arn\)$/\1\n  managed_policy_arns  = []/' "$dir/opentofu/modules/workstation/autostop.tf"
must_grep managed-policy-arns 'managed_policy_arns' "$dir/opentofu/modules/workstation/autostop.tf"
expect managed-policy-arns "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf:$line: managed_policy_arns of aws_iam_role is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)"

dir=$(copy inline-policy)
sed -i 's/^\([[:space:]]*permissions_boundary = local.permissions_boundary_arn\)$/\1\n  inline_policy {}/' "$dir/opentofu/modules/workstation/autostop.tf"
must_grep inline-policy 'inline_policy {}' "$dir/opentofu/modules/workstation/autostop.tf"
expect inline-policy "$dir" 1 \
    "Error: opentofu/modules/workstation/autostop.tf:$line: inline_policy of aws_iam_role is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)"

# インスタンスのロールの、秘密鍵 (/ec2/keypair/*) の値を読む道を拒む Deny
iam=opentofu/modules/workstation/iam.tf
deny_keypair="Error: $iam: no Deny statement of ssm:GetParameter, ssm:GetParameters and ssm:GetParameterHistory on arn:*:ssm:*:*:parameter\${local.keypair_parameter_prefix}*"
deny_bypath="Error: $iam: no Deny statement of ssm:GetParametersByPath on *"

dir=$(copy deny-removed)
sed -i '/^resource "aws_iam_role_policy" "deny_keypair_read" {$/,/^}$/d' "$dir/$iam"
if grep -q 'resource "aws_iam_role_policy" "deny_keypair_read"' "$dir/$iam"; then
    fail "deny-removed: the edit did not apply (aws_iam_role_policy.deny_keypair_read is still there)"
fi
expect deny-removed "$dir" 1 \
    "Error: $iam: the keypair Deny (data.aws_iam_policy_document.deny_keypair_read) is not attached to aws_iam_role.instance"

# Allow にすると、Deny でなくなるうえ、boundary に無い Action を許すことになる
dir=$(copy deny-to-allow)
sed -i '0,/effect    = "Deny"/s//effect    = "Allow"/' "$dir/$iam"
must_grep deny-to-allow 'effect    = "Allow"' "$dir/$iam"
expect deny-to-allow "$dir" 1 "$(
    echo "Error: $iam: ssm:GetParameterHistory is not in $boundary"
    echo "$deny_keypair"
)"

dir=$(copy prefix-shifted)
sed -i 's|parameter${local.keypair_parameter_prefix}\*|parameter/ec2/keypairs/*|' "$dir/$iam"
must_grep prefix-shifted 'parameter/ec2/keypairs/\*' "$dir/$iam"
expect prefix-shifted "$dir" 1 "$deny_keypair"

# 値が同じでも、local を使わずに書くと、片方だけ変えたときに Deny が黙って外れる
dir=$(copy prefix-literal)
sed -i 's|parameter${local.keypair_parameter_prefix}\*|parameter/ec2/keypair/*|' "$dir/$iam"
must_grep prefix-literal 'parameter/ec2/keypair/\*' "$dir/$iam"
expect prefix-literal "$dir" 1 "$deny_keypair"

dir=$(copy name-literal)
sed -i 's|"${local.keypair_parameter_prefix}${aws_key_pair.this.key_pair_id}"|"/ec2/keypair/${aws_key_pair.this.key_pair_id}"|' "$dir/opentofu/modules/workstation/keypair.tf"
must_grep name-literal '"/ec2/keypair/${aws_key_pair' "$dir/opentofu/modules/workstation/keypair.tf"
expect name-literal "$dir" 1 \
    "Error: opentofu/modules/workstation/keypair.tf: the name of aws_ssm_parameter does not start with \${local.keypair_parameter_prefix}"

dir=$(copy local-changed)
sed -i 's|keypair_parameter_prefix = "/ec2/keypair/"|keypair_parameter_prefix = "/ec2/keys/"|' "$dir/opentofu/modules/workstation/main.tf"
must_grep local-changed 'keypair_parameter_prefix = "/ec2/keys/"' "$dir/opentofu/modules/workstation/main.tf"
expect local-changed "$dir" 1 \
    "Error: opentofu/modules/workstation/main.tf: local.keypair_parameter_prefix is not \"/ec2/keypair/\""

dir=$(copy action-reduced)
sed -i 's/, "ssm:GetParameterHistory"\]/]/' "$dir/$iam"
if grep -q 'ssm:GetParameterHistory' "$dir/$iam"; then
    fail "action-reduced: the edit did not apply (ssm:GetParameterHistory is still in $iam)"
fi
expect action-reduced "$dir" 1 "$deny_keypair"

# パスで引くと、IAM はパスの ARN で評価しうるので、keypair の ARN に絞った Deny では止まらない
dir=$(copy bypath-narrowed)
sed -i '/"ssm:GetParametersByPath"/{n;s|resources = \["\*"\]|resources = ["arn:*:ssm:*:*:parameter${local.keypair_parameter_prefix}*"]|}' "$dir/$iam"
if [ "$(grep -c 'parameter${local.keypair_parameter_prefix}\*' "$dir/$iam")" != 2 ]; then
    fail "bypath-narrowed: the edit did not apply (want the keypair ARN in both statements)"
fi
expect bypath-narrowed "$dir" 1 "$deny_bypath"

dir=$(copy other-role)
sed -i '/^resource "aws_iam_role_policy" "deny_keypair_read" {$/,/^}$/s/role   = aws_iam_role\.instance\.id/role   = aws_iam_role.scheduler.id/' "$dir/$iam"
must_grep other-role 'role   = aws_iam_role.scheduler.id' "$dir/$iam"
expect other-role "$dir" 1 \
    "Error: $iam: the keypair Deny (data.aws_iam_policy_document.deny_keypair_read) is not attached to aws_iam_role.instance"

# Deny の Action は、boundary に要る Action に数えない
dir=$(copy deny-not-counted)
sed -i 's/actions   = \["ssm:GetParametersByPath"\]/actions   = ["ssm:GetParametersByPath", "ssm:DeleteParameter"]/' "$dir/$iam"
must_grep deny-not-counted '"ssm:DeleteParameter"' "$dir/$iam"
expect deny-not-counted "$dir" 0

# actions の書き方が変わって 1 つも読めないときは、黙って通らずに落ちる
dir=$(copy unreadable)
sed -i -E 's/^([[:space:]]*)actions([[:space:]]*=)/\1action_list\2/' "$dir"/opentofu/modules/*/*.tf
expect unreadable "$dir" 1 "$(
    echo "Error: no action found in the aws_iam_policy_document blocks of opentofu/modules"
    echo "$deny_keypair"
    echo "$deny_bypath"
)"

# boundary の Action を 1 行に 1 つで書かないと (引用符つきも)、読めないことを先に言い、モジュールの Action も全部挙げる
dir=$(copy quoted)
sed -i -E 's/^([[:space:]]*- )([a-z0-9-]+:[A-Za-z0-9*]+)[[:space:]]*$/\1"\2"/' "$dir/$boundary"
expect quoted "$dir" 1 "$(
    echo "Error: no action found in $boundary (one per line: - <service>:<action>)"
    for a in network/main.tf:logs:CreateLogStream network/main.tf:logs:PutLogEvents workstation/autostop.tf:ec2:StopInstances; do
        echo "Error: opentofu/modules/${a%%:*}: ${a#*:} is not in $boundary"
    done
)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
