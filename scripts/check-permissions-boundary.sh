#!/usr/bin/env bash
# permissions boundary (cloudformation/permissions-boundary.yaml) が、モジュールのロールの権限を全部含むことと、
# boundary の名前がテンプレート・codepipeline.yaml・config の 3 か所でそろうことを確かめる。AWS には触らない。
# boundary から漏れた権限は、apply は通るのに実行のときに黙って効かないため
# LIMIT: Action だけを見て、Resource の広さは見ない。HCL・YAML を正しく読まず、決まった書き方に頼る (boundary の Action は
# 1 行に 1 つ、信頼ポリシーの policy_document の名前は _assume で終わる、ブロックは行の頭の resource "..." と } で区切る)。
# 外れた書き方は、読めた集合が空になるか、下の作りの検査で落ちる。ただし policy_document の actions を変数や concat で
# 書くと読み落とす。そう書く必要が出たら、HCL を読む道具で作り直す
#
#   scripts/check-permissions-boundary.sh
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
boundary=cloudformation/permissions-boundary.yaml
pipeline=cloudformation/codepipeline.yaml
config=opentofu/modules/config/main.tf
cd "$root"
modules=(opentofu/modules/*/*.tf)

failed=0
fail() {
    echo "Error: $*" >&2
    failed=1
}

# 1 行に 1 つの "- <svc>:<Action>"
boundary_actions=$(sed -nE 's/^[[:space:]]*- ([a-z0-9-]+:[A-Za-z0-9*]+)[[:space:]]*$/\1/p' "$boundary" | sort -u)
[ -n "$boundary_actions" ] || fail "no action found in $boundary (one per line: - <service>:<action>)"

# "<ファイル> <Action>": 信頼ポリシー (_assume) 以外の policy_document の actions = [...] の中の "<svc>:<Action>"
module_actions=$(awk '
    /^data "aws_iam_policy_document" "/ { split($0, f, "\""); doc = f[4]; next }
    /^[^[:space:]]/ { doc = ""; in_actions = 0 }
    doc != "" && doc !~ /_assume$/ {
        if ($0 ~ /^[[:space:]]*actions[[:space:]]*=/) in_actions = 1
        if (in_actions) {
            s = $0
            while (match(s, /"[a-z0-9-]+:[A-Za-z0-9*]+"/)) {
                print FILENAME, substr(s, RSTART + 1, RLENGTH - 2)
                s = substr(s, RSTART + RLENGTH)
            }
            if ($0 ~ /\]/) in_actions = 0
        }
    }' "${modules[@]}")
[ -n "$module_actions" ] || fail "no action found in the aws_iam_policy_document blocks of opentofu/modules"
while read -r file action; do
    [ -n "$action" ] || continue
    grep -qxF -- "$action" <<< "$boundary_actions" || fail "$file: $action is not in $boundary"
done <<< "$module_actions"

# モジュールの IAM の作りを、検査が読める形に限る。種類ごとに "<種類>\t<ファイル>\t<行>\t<詳しく>" を出す
# - aws_iam_role は全部 permissions_boundary を持つ
# - ロールの権限は aws_iam_role_policy (policy_document の json、信頼ポリシーでないもの) と
#   aws_iam_role_policy_attachment (AWS の管理ポリシーの ARN をそのまま) だけで付ける。ほかの aws_iam_* は読まない
structure=$(awk '
    function out(kind, detail) { print kind "\t" FILENAME "\t" FNR "\t" detail }
    /^resource "/ {
        split($0, f, "\""); type = f[2]; name = f[4]; start = FNR; has_boundary = 0
        if (type ~ /^aws_iam_/ && type !~ /^aws_iam_(role|role_policy|role_policy_attachment|instance_profile)$/) out("unread", "resource \"" type "\"")
        next
    }
    /^}/ {
        if (type == "aws_iam_role" && !has_boundary) print "noboundary\t" FILENAME "\t" start "\t" name
        type = ""
        next
    }
    /^[^[:space:]]/ { type = "" }
    type == "aws_iam_role" && /^[[:space:]]*permissions_boundary[[:space:]]*=/ { has_boundary = 1 }
    type == "aws_iam_role" && /^[[:space:]]*inline_policy[[:space:]]*\{/ { out("unread", "inline_policy of aws_iam_role") }
    type == "aws_iam_role" && /^[[:space:]]*managed_policy_arns[[:space:]]*=/ { out("unread", "managed_policy_arns of aws_iam_role") }
    type == "aws_iam_role_policy" && /^[[:space:]]*policy[[:space:]]*=/ {
        if (match($0, /data\.aws_iam_policy_document\.[A-Za-z0-9_-]+\.json[[:space:]]*$/)) {
            doc = substr($0, RSTART + 29)
            sub(/\.json[[:space:]]*$/, "", doc)
            if (doc ~ /_assume$/) out("assume", doc)
        } else {
            out("policy", "")
        }
    }
    type == "aws_iam_role_policy_attachment" && /^[[:space:]]*policy_arn[[:space:]]*=/ {
        if (match($0, /"arn:aws:iam::aws:policy\/[A-Za-z0-9]+"[[:space:]]*$/)) {
            arn = substr($0, RSTART + 1, RLENGTH)
            sub(/".*$/, "", arn)
            sub(/.*\//, "", arn)
            out("managed", arn)
        } else {
            out("arn", "")
        }
    }' "${modules[@]}")
while IFS=$'\t' read -r kind file line detail; do
    case $kind in
        noboundary) fail "$file:$line: aws_iam_role.$detail has no permissions_boundary" ;;
        unread) fail "$file:$line: $detail is not read by the check (give a role its policies with aws_iam_role_policy or aws_iam_role_policy_attachment)" ;;
        policy) fail "$file:$line: the policy of aws_iam_role_policy is not data.aws_iam_policy_document.<name>.json (the check reads Actions only from policy documents)" ;;
        assume) fail "$file:$line: the policy of aws_iam_role_policy is data.aws_iam_policy_document.$detail, which the check skips as a trust policy (*_assume)" ;;
        arn) fail "$file:$line: the policy_arn of aws_iam_role_policy_attachment is not \"arn:aws:iam::aws:policy/<name>\" (the check cannot read it)" ;;
        # 付ける管理ポリシーは、boundary にその名前の Sid の文がある (中身は AWS の管理ポリシーの写し)
        managed)
            grep -qE "^[[:space:]]*- Sid: ${detail}[[:space:]]*\$" "$boundary" ||
                fail "$file: the managed policy $detail has no statement with Sid: $detail in $boundary"
            ;;
    esac
done <<< "$structure"

# 名前: テンプレートの ManagedPolicyName、codepipeline.yaml の条件の ARN (全部の出現)、config の permissions_boundary_name
names() {
    case $1 in
        "$boundary") sed -nE 's/^[[:space:]]*ManagedPolicyName: !Sub \$\{ProjectName\}-\$\{Environment\}-([A-Za-z0-9-]+)[[:space:]]*$/\1/p' "$1" ;;
        "$pipeline") grep -oE ':policy/\$\{ProjectName\}-\$\{Environment\}-[A-Za-z0-9-]+' "$1" | sed 's/.*\${Environment}-//' ;;
        "$config") awk '/^output "permissions_boundary_name"/ { o = 1 } o && /value/ { print; exit }' "$1" |
            sed -nE 's/.*"\$\{local\.resource_prefix\}-([A-Za-z0-9-]+)".*/\1/p' ;;
    esac | sort -u | paste -sd ' ' -
}
want=$(names "$boundary")
for file in "$boundary" "$pipeline" "$config"; do
    if [ -z "$(names "$file")" ] || [ "$(names "$file")" != "$want" ]; then
        fail "the permissions boundary names differ: $boundary '$want', $pipeline '$(names "$pipeline")', $config '$(names "$config")'"
        break
    fi
done

[ "$failed" = 0 ] || exit 1
echo "permissions boundary '$want': $(wc -l <<< "$module_actions") module action(s) are in $boundary"
