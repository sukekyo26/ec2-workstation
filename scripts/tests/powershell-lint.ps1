<#
.SYNOPSIS
    Checks scripts/**/*.ps1 with the PowerShell parser and PSScriptAnalyzer.
.DESCRIPTION
    CI runs this on Windows PowerShell 5.1, the version the SSH ProxyCommand uses.
    A run on a local pwsh 7 is only a hint: its parser accepts syntax that 5.1 rejects.
    Saved with a BOM like the other scripts; also kept ASCII only so that 5.1 still reads it if the BOM is lost.
#>
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptsDir = Join-Path $root 'scripts'
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'

$module = Get-Module -ListAvailable -Name PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if (-not $module) {
    Write-Output 'ERROR: PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser'
    exit 1
}
Import-Module $module
Write-Output ("PowerShell {0} ({1}), PSScriptAnalyzer {2}" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $module.Version)

$files = @(Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -Recurse -File)
$problems = 0
foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length + 1)
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        Write-Output ("{0}:{1} ParseError {2}" -f $relative, $parseError.Extent.StartLineNumber, $parseError.Message)
        $problems++
    }
}

# The three client scripts carry the same aws helpers: the ProxyCommand runs a lone copy of start-ec2-and-wait.ps1, so
# they cannot share a file. The statements that set $awsCli, $utf8NoBom and $stderrWriter and the functions Write-Stderr
# and Invoke-AwsCli are the same text in each (comments in the bodies too), and come before the first call of Invoke-AwsCli
$sharedNames = @('$awsCli', '$utf8NoBom', '$stderrWriter', '$stderrWriter.AutoFlush', '$stderrWriter.NewLine', 'function Write-Stderr', 'function Invoke-AwsCli')
$sharedTexts = @{}
foreach ($name in @('start-ec2.ps1', 'start-ec2-and-wait.ps1', 'setup-remote-ssh.ps1')) {
    $relative = "scripts/client/$name"
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Join-Path $scriptsDir 'client') $name), [ref]$null, [ref]$null)
    $firstCall = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-AwsCli' }, $true) |
            Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    $found = @{}
    foreach ($statement in $ast.EndBlock.Statements) {
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $key = $statement.Left.Extent.Text
        } elseif ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $key = "function $($statement.Name)"
        } else {
            continue
        }
        if ($sharedNames -notcontains $key) {
            continue
        }
        $found[$key] = $true
        $sharedTexts[$key] = @($sharedTexts[$key] | Where-Object { $_ }) + @("$relative`n" + ($statement.Extent.Text -replace "`r`n", "`n"))
        if ($firstCall.Count -eq 0 -or $statement.Extent.StartOffset -gt $firstCall[0].Extent.StartOffset) {
            Write-Output ("{0}:{1} SharedAwsHelpers {2} comes after the first call of Invoke-AwsCli" -f $relative, $statement.Extent.StartLineNumber, $key)
            $problems++
        }
    }
    foreach ($key in $sharedNames) {
        if (-not $found[$key]) {
            Write-Output ("{0} SharedAwsHelpers {1} is missing at the top level" -f $relative, $key)
            $problems++
        }
    }
}
foreach ($key in $sharedNames) {
    $texts = @($sharedTexts[$key] | Where-Object { $_ } | ForEach-Object { ($_ -split "`n", 2)[1] } | Sort-Object -Unique -CaseSensitive)
    if ($texts.Count -gt 1) {
        $owners = @($sharedTexts[$key] | Where-Object { $_ } | ForEach-Object { ($_ -split "`n", 2)[0] })
        Write-Output ("scripts/client SharedAwsHelpers {0} differs between {1}" -f $key, ($owners -join ', '))
        $problems++
    }
}

foreach ($result in @(Invoke-ScriptAnalyzer -Path $scriptsDir -Recurse -Settings $settings)) {
    # A diagnostic that is not tied to a file has no ScriptPath; still report and count it
    if ($result.ScriptPath) {
        $relative = $result.ScriptPath.Substring($root.Length + 1)
    } else {
        $relative = '<no file>'
    }
    Write-Output ("{0}:{1} {2} {3} {4}" -f $relative, $result.Line, $result.Severity, $result.RuleName, $result.Message)
    $problems++
}

Write-Output ("checked {0} file(s), {1} problem(s)" -f $files.Count, $problems)
if ($problems -gt 0) {
    exit 1
}
