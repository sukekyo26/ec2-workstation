#!/usr/bin/env bash
# OpenTofu のルート opentofu/stacks/<stack> を、state の bucket・key を決めて init する (手で plan・output などを打つ前に)。
# workstations はユーザーの workspace も選ぶ (1 つの workspace = 1 人のユーザーの state)。
#
#   TF_STATE_BUCKET=<bucket> scripts/tofu-init.sh network
#   TF_STATE_BUCKET=<bucket> scripts/tofu-init.sh workstations <username>
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

usage() {
    die "usage: TF_STATE_BUCKET=<bucket> $0 network | workstations <username>"
}

case "${1:-}" in
    network)
        if [ $# -ne 1 ]; then
            usage
        fi
        check_environment
        init_stack network
        ;;
    workstations)
        if [ $# -ne 2 ]; then
            usage
        fi
        username=$2
        check_environment
        init_stack workstations
        known=()
        names=$(config_usernames)
        mapfile -t known <<< "$names"
        names=$(user_workspaces)
        if [ -n "$names" ]; then
            mapfile -t -O "${#known[@]}" known <<< "$names"
        fi
        # 打ち間違いで空の workspace を作らない。設定から消えたユーザーは、state が残っていれば選べる (手で destroy するため)
        if ! in_list "$username" "${known[@]}"; then
            die "$username is not a username in workstation-config.json and has no state"
        fi
        tofu -chdir="$(stack_dir workstations)" workspace select -or-create "$username"
        ;;
    *) usage ;;
esac
