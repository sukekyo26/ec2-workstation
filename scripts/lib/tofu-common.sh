# shellcheck shell=bash
# tofu-init.sh・tofu-deploy.sh・tofu-destroy.sh が読む共通の部品。
# set -e の下で読まれるので、関数は `[ ... ] && cmd` の形で終わらせない (条件が偽のとき rc=1 で呼び出し元が止まる)

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIG_FILE="$REPO_ROOT/workstation-config.json"
STACKS_DIR="$REPO_ROOT/opentofu/stacks"
# shellcheck disable=SC2034 # tofu-init.sh と tofu-deploy.sh が使う
STATE_REGION=ap-northeast-1

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "==> $*" >&2
}

# TF_WORKSPACE は workspace の選択を上書きし、state の key を黙って変える
require_no_tf_workspace() {
    if [ -n "${TF_WORKSPACE:-}" ]; then
        die "unset TF_WORKSPACE: it overrides the workspace OpenTofu selects, so the state would be read from another key"
    fi
}

require_state_bucket() {
    if [ -z "${TF_STATE_BUCKET:-}" ]; then
        die "set TF_STATE_BUCKET to the S3 bucket that keeps the OpenTofu state (see opentofu/README.md)"
    fi
}

# <projectName>/<environment>。state の key はすべてこの下に置く
state_key_prefix() {
    jq -er '"\(.projectName)/\(.environment)"' "$CONFIG_FILE"
}

stack_dir() {
    case "$1" in
        network | workstations) echo "$STACKS_DIR/$1" ;;
        *) die "unknown stack '$1' (network or workstations)" ;;
    esac
}
