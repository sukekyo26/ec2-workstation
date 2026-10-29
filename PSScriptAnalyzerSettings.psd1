# PSScriptAnalyzer settings for scripts/**/*.ps1 (used by scripts/tests/powershell-lint.ps1)
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts are interactive and print colored progress with Write-Host.
        # Write-Output would mix the messages into function return values.
        'PSAvoidUsingWriteHost'
        # Adding a BOM changes how Windows PowerShell 5.1 decodes the files (see the troubles record #9)
        'PSUseBOMForUnicodeEncodedFile'
    )
    Rules        = @{
        # README requires PowerShell 5.1 or later. The CI parses with 5.1; this rule also catches
        # 7-only syntax when the check runs on a local pwsh 7
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
