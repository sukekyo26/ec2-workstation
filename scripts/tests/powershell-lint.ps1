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
