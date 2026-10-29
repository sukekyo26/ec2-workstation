#!/usr/bin/env bash
# OpenTofu のルート opentofu/stacks/<stack> を、state の bucket・key を決めて init する。
# state の key を組み立てるのはここだけ (<projectName>/<environment>/<stack>.tfstate)。
#
#   TF_STATE_BUCKET=<bucket> scripts/tofu-init.sh <network|workstations>
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

if [ $# -ne 1 ]; then
    die "usage: TF_STATE_BUCKET=<bucket> $0 <network|workstations>"
fi
stack=$1
dir=$(stack_dir "$stack")
require_state_bucket
require_no_tf_workspace
prefix=$(state_key_prefix)

# 前に選んだ workspace が消されていると init が止まるので、選択を default に戻す
rm -f "$dir/.terraform/environment"
tofu -chdir="$dir" init -input=false -reconfigure \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=$prefix/$stack.tfstate" \
    -backend-config="region=$STATE_REGION"
