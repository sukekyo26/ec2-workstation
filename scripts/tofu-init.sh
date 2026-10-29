#!/usr/bin/env bash
# OpenTofu のルート opentofu/stacks/<stack> を、state の bucket・key を決めて init する (手で plan・output などを打つ前に)。
#
#   TF_STATE_BUCKET=<bucket> scripts/tofu-init.sh <network|workstations>
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

if [ $# -ne 1 ]; then
    die "usage: TF_STATE_BUCKET=<bucket> $0 <network|workstations>"
fi
check_environment
init_stack "$1"
