<#
.SYNOPSIS
    Checks start-ec2-and-wait.ps1 and start-ec2.ps1 with a fake AWS CLI.
.DESCRIPTION
    Each script is copied to a temp directory with its one $awsCli line pointed at a fake aws.cmd, and run in a
    child powershell.exe (the same one that runs this test). start-ec2-and-wait.ps1 runs as the SSH ProxyCommand,
    so its stdout must carry nothing but the session (the fake prints SSH-2.0-fake). A failed aws call must stop the
    script at once: each run is killed after 10 seconds.
    Windows only (the fake is a .cmd). Saved with a BOM and ASCII only, like the other scripts.
#>
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    Write-Output 'skip start-ec2.test.ps1: the fake aws is a .cmd and runs only on Windows'
    exit 0
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$work = Join-Path ([IO.Path]::GetTempPath()) ("start-ec2-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$utf8Bom = [Text.UTF8Encoding]::new($true)

# The fake dispatches on the first three arguments only (%1 %2 %3), so the characters in --query and --filters
# are never parsed by cmd. It logs the whole command line to FAKE_ARGS_LOG to show how the arguments arrive.
$fakeAws = Join-Path $work 'aws.cmd'
$fakeLines = @(
    '@echo off',
    'setlocal',
    'if defined FAKE_ARGS_LOG >>"%FAKE_ARGS_LOG%" echo(%*',
    'set "what=%~2"',
    'if "%~2"=="wait" set "what=wait-%~3"',
    'if "%~2"=="describe-instances" if "%~3"=="--region" set "what=lookup"',
    'if "%~2"=="describe-instances" if "%~3"=="--instance-ids" set "what=state"',
    'set known=',
    'for %%w in (lookup state start-instances wait-instance-stopped wait-instance-running describe-instance-information start-session) do if "%what%"=="%%w" set known=1',
    'if not defined known (',
    '    >&2 echo fake aws: unexpected call: %what%',
    '    exit /b 2',
    ')',
    'if "%FAKE_FAIL%"=="%what%" (',
    '    >&2 echo fake aws: %what% failed',
    '    exit /b 1',
    ')',
    'if "%FAKE_WARN%"=="1" >&2 echo fake aws: warning from %what%',
    'if "%what%"=="lookup" echo i-0123456789abcdef0',
    'if "%what%"=="state" echo %FAKE_STATE%',
    'if "%what%"=="start-instances" (',
    '    echo {',
    '    echo     "StartingInstances": []',
    '    echo }',
    ')',
    'if "%what%"=="describe-instance-information" echo Online',
    'if "%what%"=="start-session" echo SSH-2.0-fake',
    'exit /b 0'
)
[IO.File]::WriteAllText($fakeAws, ($fakeLines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)

$awsCliLine = '$awsCli = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"'

# Copy a script with its $awsCli line pointed at the fake, keeping the BOM (5.1 reads a file without one in the ANSI code page)
function Copy-WithFakeAws {
    param([string]$Name)
    $text = [IO.File]::ReadAllText((Join-Path $root "scripts\$Name"))
    $lines = $text -split "`r?`n"
    $found = @($lines | Where-Object { $_ -eq $awsCliLine }).Count
    if ($found -ne 1) {
        throw "$Name has $found lines '$awsCliLine', want exactly 1"
    }
    $copy = Join-Path $work $Name
    [IO.File]::WriteAllText($copy, $text.Replace($awsCliLine, "`$awsCli = `"$fakeAws`""), $utf8Bom)
    return $copy
}

$waitScript = Copy-WithFakeAws 'start-ec2-and-wait.ps1'
$startScript = Copy-WithFakeAws 'start-ec2.ps1'
$powershell = (Get-Process -Id $PID).Path
$failures = 0

function Add-Failure {
    param([string]$Message)
    Write-Output "FAIL: $Message"
    $script:failures++
}

# Run a script in a child powershell.exe with the given environment, killing it (and the fake aws under it) after 10 seconds.
# The output is read asynchronously: a synchronous ReadToEnd() before WaitForExit would block the timeout, and after a
# kill the grandchild cmd.exe may keep the pipes open, so a killed run does not wait for the reads.
function Invoke-Case {
    param([string]$Script, [string[]]$Arguments, [hashtable]$Environment)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $powershell
    $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script`" " + ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($key in @('FAKE_STATE', 'FAKE_FAIL', 'FAKE_WARN', 'FAKE_ARGS_LOG')) {
        $psi.EnvironmentVariables.Remove($key)
    }
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = $Environment[$key]
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) {
        & taskkill /T /F /PID $process.Id 2>&1 | Out-Null
        return @{ TimedOut = $true; Seconds = $watch.Elapsed.TotalSeconds }
    }
    $process.WaitForExit()
    [void]$stdout.Wait(5000)
    [void]$stderr.Wait(5000)
    return @{
        TimedOut = $false
        Seconds = $watch.Elapsed.TotalSeconds
        ExitCode = $process.ExitCode
        Stdout = @($stdout.Result -split "`r?`n" | Where-Object { $_ -ne '' })
        Stderr = $stderr.Result
    }
}

function Write-Case {
    param([string]$Name, [hashtable]$Result)
    if ($Result.TimedOut) {
        Write-Output ("{0}: killed after {1:N1}s" -f $Name, $Result.Seconds)
        return
    }
    Write-Output ("{0}: rc={1} {2:N1}s stdout=[{3}]" -f $Name, $Result.ExitCode, $Result.Seconds, ($Result.Stdout -join ' | '))
}

$waitArgs = @('ws', 'ap-northeast-1', '22')
$startArgs = @('-InstanceName', 'ws', '-Region', 'ap-northeast-1')

# How long one call of the fake takes on this machine
$env:FAKE_STATE = 'running'
$seconds = (Measure-Command { & $fakeAws ec2 describe-instances --instance-ids i-0 --region ap-northeast-1 | Out-Null }).TotalSeconds
Remove-Item Env:FAKE_STATE
Write-Output ("fake aws: one call took {0:N2}s" -f $seconds)

# How the arguments reach the fake (the --filters and --query values must arrive whole)
$argsLog = Join-Path $work 'args.log'
$null = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment @{ FAKE_STATE = 'running'; FAKE_ARGS_LOG = $argsLog }
Write-Output 'fake aws: arguments as received'
Get-Content $argsLog | ForEach-Object { Write-Output "    $_" }
foreach ($want in @('--filters Name=tag:Name,Values=ws Name=instance-state-name,Values=pending,running,stopping,stopped',
        '--query Reservations[].Instances[].InstanceId',
        '--query Reservations[0].Instances[0].State.Name',
        '--query InstanceInformationList[0].PingStatus')) {
    if (-not (Select-String -Path $argsLog -SimpleMatch -Quiet -Pattern $want)) {
        Add-Failure "arguments: the fake did not receive '$want'"
    }
}

# Success: the ProxyCommand's stdout is the session alone, also when aws prints a warning on stderr
foreach ($case in @(
        @{ Name = 'stopped' },
        @{ Name = 'stopping' },
        @{ Name = 'pending' },
        @{ Name = 'running' },
        @{ Name = 'running'; Warn = '1' })) {
    $environment = @{ FAKE_STATE = $case.Name }
    $label = "start-ec2-and-wait $($case.Name)"
    if ($case.Warn) {
        $environment.FAKE_WARN = '1'
        $label += ' with warnings'
    }
    $result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or ($result.Stdout -join "`n") -ne 'SSH-2.0-fake') {
        Add-Failure "${label}: want rc=0 and stdout 'SSH-2.0-fake' alone"
    }

    $label = "start-ec2 $($case.Name)" + $(if ($case.Warn) { ' with warnings' } else { '' })
    $result = Invoke-Case -Script $startScript -Arguments $startArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or ($result.Stdout -join "`n") -notmatch 'EC2 instance is ready') {
        Add-Failure "${label}: want rc=0 and the ready message"
    }
}

# A failed aws call stops the script at once with the reason; the ProxyCommand's stdout stays empty
foreach ($case in @(
        @{ State = 'stopped'; Fail = 'start-instances' },
        @{ State = 'stopped'; Fail = 'wait-instance-running' },
        @{ State = 'stopping'; Fail = 'wait-instance-stopped' },
        @{ State = 'stopping'; Fail = 'start-instances' },
        @{ State = 'stopping'; Fail = 'wait-instance-running' },
        @{ State = 'pending'; Fail = 'wait-instance-running' },
        @{ State = 'running'; Fail = 'describe-instance-information' })) {
    $environment = @{ FAKE_STATE = $case.State; FAKE_FAIL = $case.Fail }
    $reason = "fake aws: $($case.Fail) failed"

    $label = "start-ec2-and-wait $($case.State), $($case.Fail) fails"
    $result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1 -or $result.Stdout.Count -ne 0 -or $result.Stderr -notmatch [regex]::Escape($reason)) {
        Add-Failure "${label}: want rc=1 within 10s, empty stdout, and '$reason' on stderr"
    }

    $label = "start-ec2 $($case.State), $($case.Fail) fails"
    $result = Invoke-Case -Script $startScript -Arguments $startArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1 -or (($result.Stdout -join "`n") + $result.Stderr) -notmatch [regex]::Escape($reason)) {
        Add-Failure "${label}: want rc=1 within 10s and '$reason'"
    }
}

Remove-Item -Recurse -Force $work
if ($failures -ne 0) {
    Write-Output "$failures check(s) failed"
    exit 1
}
Write-Output 'all checks passed'
