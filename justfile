shfmt_flags := "-i 4 -ci -sr"

# レシピ一覧を表示
default:
    @just --list

# ローカル CI: GitHub Actions と同等のチェックを一括実行
ci: validate-config tofu-check shellcheck shfmt-check gitleaks-scan

# workstation-config を JSON Schema で検証
validate-config:
    npx --yes ajv-cli@5 validate -s workstation-config.schema.json -d workstation-config.json

# OpenTofu のフォーマットチェックと validate
tofu-check:
    tofu -chdir=opentofu fmt -check -recursive
    tofu -chdir=opentofu init -backend=false
    tofu -chdir=opentofu validate

# シェルスクリプトの静的解析
shellcheck:
    git ls-files '*.sh' | xargs shellcheck --severity=error

# シェルスクリプトのフォーマットチェック
shfmt-check:
    git ls-files '*.sh' | xargs shfmt {{ shfmt_flags }} -d

# シェルスクリプトを自動フォーマット
shfmt-fix:
    git ls-files '*.sh' | xargs shfmt {{ shfmt_flags }} -w

# シークレットスキャン（git 履歴を含む）
gitleaks-scan:
    gitleaks git --redact --verbose .
