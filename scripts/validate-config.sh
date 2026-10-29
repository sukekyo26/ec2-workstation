#!/usr/bin/env bash
# workstation-config.json を workstation-config.schema.json で検証する (jv は scripts/install/install-jv.sh で入れる)。
# tofu-deploy.sh・tofu-init.sh も、tofu を呼ぶ前に同じ検証をする
#
#   scripts/validate-config.sh
set -euo pipefail

# shellcheck source=scripts/lib/tofu-common.sh
. "$(dirname "$0")/lib/tofu-common.sh"

validate_config
