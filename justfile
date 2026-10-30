# レシピ一覧を表示
default:
    @just --list

# ローカル CI: GitHub Actions と同等のチェックを一括実行
ci: validate-config check-os-images check-user-data-size check-permissions-boundary tofu-check scripts-test shellcheck shfmt-check pwsh-check gitleaks-scan

# workstation-config を JSON Schema で検証（jv は scripts/install/install-jv.sh で入れる）
validate-config:
    scripts/validate-config.sh

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

# permissions boundary がモジュールのロールの Action を全部含み、名前が 3 か所でそろうか（CI と同じ）
check-permissions-boundary:
    scripts/check-permissions-boundary.sh

# OpenTofu のフォーマットチェックと validate
tofu-check:
    #!/usr/bin/env bash
    set -euo pipefail
    tofu -chdir=opentofu fmt -check -recursive
    for stack in opentofu/stacks/*/; do
        tofu -chdir="$stack" init -backend=false
        tofu -chdir="$stack" validate
    done

# デプロイ・削除のスクリプトの順番と止まり方を偽の tofu で、道具の取り方を偽の curl で、format-shell.sh を偽の shfmt で、start-ec2 の 2 本と setup-remote-ssh.sh を偽の aws で、check-permissions-boundary.sh を壊した写しで確かめる（CI と同じ）
scripts-test:
    scripts/tests/tofu-deploy.test.sh
    scripts/tests/install-tools.test.sh
    scripts/tests/format-shell.test.sh
    scripts/tests/start-ec2.test.sh
    scripts/tests/setup-remote-ssh.test.sh
    scripts/tests/check-permissions-boundary.test.sh
    scripts/tests/data-volume-fs.test.sh
    scripts/tests/fstab-entry.test.sh

# シェルスクリプトの静的解析（対象は scripts/format-shell.sh の一覧）
shellcheck:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/format-shell.sh --list | xargs -0r shellcheck --severity=error

# PowerShell スクリプトの構文と PSScriptAnalyzer。手元の pwsh 7 での目安で、Windows PowerShell 5.1 での検査は CI で見る（pwsh が無ければ飛ばす）
# scripts/install/install-psscriptanalyzer.sh で入れた PSScriptAnalyzer も読む。EC2WS_REQUIRE_PWSH=yes (CodePipeline の Check) なら、pwsh が無いときは飛ばさずに止まる
pwsh-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v pwsh > /dev/null; then
        if [ "${EC2WS_REQUIRE_PWSH:-}" = yes ]; then
            echo "pwsh-check: pwsh is not installed (install it with scripts/install/install-pwsh.sh)" >&2
            exit 1
        fi
        echo "skip pwsh-check: pwsh is not installed (CI checks with Windows PowerShell 5.1)"
        exit 0
    fi
    modules=$(bash -c '. scripts/lib/tools.sh; psmodules_path')
    export PSModulePath="$modules${PSModulePath:+:$PSModulePath}"
    pwsh -NoProfile -File scripts/tests/powershell-lint.ps1

# シェルスクリプトのフォーマットチェック（CI と同じ。書式は .editorconfig、shfmt は scripts/install/install-shfmt.sh で入れる）
shfmt-check:
    scripts/format-shell.sh --check

# シェルスクリプトを自動フォーマット
shfmt-fix:
    scripts/format-shell.sh --write

# シークレットスキャン（git 履歴を含む）
gitleaks-scan:
    gitleaks git --redact --verbose .
