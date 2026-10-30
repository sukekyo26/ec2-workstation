#!/usr/bin/env bash
# permissions boundary (cloudformation/permissions-boundary.yaml) が、モジュールのロールの権限を全部含むことと、
# boundary の名前がテンプレート・codepipeline.yaml・config の 3 か所でそろうことを確かめる。AWS には触らない。
# boundary から漏れた権限は、apply は通るのに実行のときに黙って効かないため
# LIMIT: Action だけを見て、Resource の広さは見ない。HCL・YAML を正しく読まず、決まった書き方に頼る (boundary の Action は
# 1 行に 1 つ、信頼ポリシーの policy_document の名前は _assume で終わる、インラインのポリシーは policy_document から渡す)。
# 外れた書き方は、読めた集合が空になるか、policy の形の検査で落ちる。ただし policy_document の actions を変数や concat で
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

# インラインのポリシーは policy_document から渡す (ほかの形の Action は上で読めないため)
while IFS=: read -r file line; do
    [ -n "$file" ] || continue
    fail "$file:$line: the policy of aws_iam_role_policy is not data.aws_iam_policy_document.<name>.json (the check reads Actions only from policy documents)"
done < <(awk '
    /^resource "aws_iam_role_policy" "/ { in_policy = 1; next }
    /^[^[:space:]]/ { in_policy = 0 }
    in_policy && /^[[:space:]]*policy[[:space:]]*=/ && $0 !~ /=[[:space:]]*data\.aws_iam_policy_document\.[A-Za-z0-9_-]+\.json[[:space:]]*$/ {
        print FILENAME ":" FNR
    }' "${modules[@]}")

# 付ける管理ポリシーは、boundary にその名前の Sid の文がある (中身は AWS の管理ポリシーの写し)
while IFS=: read -r file name; do
    [ -n "$name" ] || continue
    grep -qE "^[[:space:]]*- Sid: ${name}[[:space:]]*$" "$boundary" ||
        fail "$file: the managed policy $name has no statement with Sid: $name in $boundary"
done < <(grep -oE 'policy_arn[[:space:]]*=[[:space:]]*"arn:aws:iam::aws:policy/[A-Za-z0-9]+"' "${modules[@]}" |
    sed -E 's|^([^:]+):.*policy/([A-Za-z0-9]+)"$|\1:\2|')

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
