shfmt_flags := "-i 4 -ci -sr"
shell_files := "'*.sh' '*.sh.tftpl'"

# レシピ一覧を表示
default:
    @just --list

# ローカル CI: GitHub Actions と同等のチェックを一括実行
ci: validate-config check-os-images check-user-data-size tofu-check shellcheck shfmt-check gitleaks-scan

# workstation-config を JSON Schema で検証
validate-config:
    npx --yes ajv-cli@5 validate -s workstation-config.schema.json -d workstation-config.json

# スキーマの os の enum と os-images.json のキーが一致するか（CI と同じ比較）
check-os-images:
    #!/usr/bin/env bash
    diff <(jq -S '.definitions.os.enum | sort' workstation-config.schema.json) <(jq -S 'keys | sort' opentofu/modules/workstation/os-images.json)

# user-data が EC2 の上限 (base64 前で 16KB) に収まるか（CI と同じ比較）。余裕を見て base64 後の長さで 16,384 未満を見る。
# gzip -9 と tofu の base64gzip の圧縮の違いと、テンプレートの展開で増える分は、この余裕に収まる
check-user-data-size:
    #!/usr/bin/env bash
    set -euo pipefail
    size=$(gzip -9 -c opentofu/modules/workstation/templates/user-data.sh.tftpl | base64 -w0 | wc -c)
    echo "user-data (gzip+base64): $size bytes"
    [ "$size" -lt 16384 ]

# OpenTofu のフォーマットチェックと validate
tofu-check:
    tofu -chdir=opentofu fmt -check -recursive
    tofu -chdir=opentofu init -backend=false
    tofu -chdir=opentofu validate

# シェルスクリプトの静的解析
shellcheck:
    git ls-files {{ shell_files }} | xargs shellcheck --severity=error

# シェルスクリプトのフォーマットチェック
shfmt-check:
    git ls-files {{ shell_files }} | xargs shfmt {{ shfmt_flags }} -d

# シェルスクリプトを自動フォーマット
shfmt-fix:
    git ls-files {{ shell_files }} | xargs shfmt {{ shfmt_flags }} -w

# シークレットスキャン（git 履歴を含む）
gitleaks-scan:
    gitleaks git --redact --verbose .
