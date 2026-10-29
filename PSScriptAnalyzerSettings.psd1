# PSScriptAnalyzer settings for scripts/**/*.ps1 (used by scripts/tests/powershell-lint.ps1)
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts are interactive and print colored progress with Write-Host.
        # Write-Output would mix the messages into function return values.
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        # Users run the scripts on Windows PowerShell 5.1 or PowerShell 7. The GitHub Actions CI parses with 5.1;
        # this rule also catches syntax that one of them lacks when the check runs on pwsh 7 (locally or in CodePipeline)
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
