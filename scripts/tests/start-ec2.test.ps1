<#
.SYNOPSIS
    Checks start-ec2-and-wait.ps1, start-ec2.ps1 and setup-remote-ssh.ps1 with a fake AWS CLI.
.DESCRIPTION
    Each script runs in a child powershell.exe (the same one that runs this test) whose PATH finds a fake aws.cmd
    (in a folder with a space) before the real AWS CLI, and an aws.ps1 decoy that exits 99 before both: the scripts
    must take aws from Get-Command -CommandType Application. start-ec2-and-wait.ps1 runs as the SSH ProxyCommand,
    so its stdout must carry nothing but the session (the fake prints SSH-2.0-fake). A failed aws call must stop the
    script at once: each run is killed after 10 seconds (EC2WS_SSM_POLL_INTERVAL=1 shortens the wait between SSM checks).
    setup-remote-ssh.ps1 runs with USERPROFILE in the temp directory; its ProxyCommand must not load the user's profile
    (the output would go into the SSH channel).
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
try {
# The fake dispatches on the first three arguments only (%1 %2 %3), so the characters in --query and --filters
# are never parsed by cmd. It logs the whole command line to FAKE_ARGS_LOG to show how the arguments arrive.
$fakeDir = Join-Path $work 'aws cli'
New-Item -ItemType Directory -Path $fakeDir | Out-Null
$fakeAws = Join-Path $fakeDir 'aws.cmd'
$fakeLines = @(
    '@echo off',
    'setlocal',
    'if defined FAKE_ARGS_LOG >>"%FAKE_ARGS_LOG%" echo(%*',
    'if "%~1"=="--version" goto :version',
    'set "what=%~2"',
    'if "%~2"=="wait" set "what=wait-%~3"',
    'if "%~2"=="describe-instances" if "%~3"=="--region" set "what=lookup"',
    'if "%~2"=="describe-instances" if "%~3"=="--instance-ids" set "what=state"',
    'set known=',
    'for %%w in (lookup state start-instances wait-instance-stopped wait-instance-running describe-instance-information start-session describe-key-pairs get-parameter) do if "%what%"=="%%w" set known=1',
    'if not defined known (',
    '    >&2 echo fake aws: unexpected call: %what%',
    '    exit /b 2',
    ')',
    'if not "%what%"=="describe-instance-information" goto :nosequence',
    'if not defined FAKE_SSM_SEQUENCE goto :nosequence',
    'set n=0',
    'if exist "%FAKE_COUNTER%" set /p n=<"%FAKE_COUNTER%"',
    'set /a n+=1',
    '>"%FAKE_COUNTER%" echo %n%',
    'set answer=Online',
    'for /f "tokens=%n% delims=," %%t in ("%FAKE_SSM_SEQUENCE%") do set "answer=%%t"',
    'if "%answer%"=="fail" goto :fail',
    'echo %answer%',
    'exit /b 0',
    ':nosequence',
    'if not "%FAKE_FAIL%"=="%what%" goto :succeed',
    ':fail',
    '>&2 echo(',
    '>&2 echo fake aws: %what% failed',
    'exit /b 1',
    ':succeed',
    'if not "%FAKE_WARN%"=="1" goto :nowarn',
    'if "%what%"=="start-session" goto :nowarn',
    '>&2 echo(',
    '>&2 echo fake aws: warning from %what%',
    ':nowarn',
    'if not "%what%"=="start-session" goto :nosession',
    'if not "%FAKE_SESSION_STDERR%"=="1" goto :nosession',
    '>&2 echo(',
    '>&2 echo fake aws: session warning',
    ':nosession',
    'if "%what%"=="lookup" if not defined FAKE_LOOKUP_IDS set "FAKE_LOOKUP_IDS=i-0123456789abcdef0"',
    'if "%what%"=="lookup" echo %FAKE_LOOKUP_IDS%',
    'if "%what%"=="state" echo %FAKE_STATE%',
    'if "%what%"=="start-instances" (',
    '    echo {',
    '    echo     "StartingInstances": []',
    '    echo }',
    ')',
    'if "%what%"=="describe-instance-information" echo Online',
    'if "%what%"=="start-session" echo SSH-2.0-fake',
    'if "%what%"=="describe-key-pairs" echo key-0123456789abcdef0',
    'if "%what%"=="get-parameter" echo FAKE PRIVATE KEY',
    'exit /b 0',
    ':version',
    'if "%FAKE_VERSION_STDERR%"=="1" (>&2 echo aws-cli/1.0.0 fake& exit /b 0)',
    'if "%FAKE_VERSION_EMPTY%"=="1" exit /b 0',
    'if not "%FAKE_VERSION_FAIL%"=="1" (echo aws-cli/2.0.0 fake& exit /b 0)',
    'echo fake aws: version stdout',
    '>&2 echo(',
    '>&2 echo fake aws: version failed',
    'exit /b 3'
)
[IO.File]::WriteAllText($fakeAws, ($fakeLines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)

# An aws that Get-Command finds before the fake only when -CommandType Application is left out
$decoyDir = Join-Path $work 'decoy'
New-Item -ItemType Directory -Path $decoyDir | Out-Null
$decoyAws = Join-Path $decoyDir 'aws.ps1'
[IO.File]::WriteAllText($decoyAws, "exit 99`r`n", [Text.Encoding]::ASCII)

# windows-latest has the real AWS CLI on PATH: the fake must come first, and the decoy before it
$testPath = "$decoyDir;$fakeDir;$env:PATH"
$savedPath = $env:PATH
$env:PATH = $testPath
try {
    $application = (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    $anyCommand = (Get-Command aws -ErrorAction SilentlyContinue | Select-Object -First 1).Path
} finally {
    $env:PATH = $savedPath
}
if ($application -ne $fakeAws) {
    throw "Get-Command aws -CommandType Application finds $application, want the fake $fakeAws"
}
if ($anyCommand -ne $decoyAws) {
    throw "Get-Command aws finds $anyCommand, want the decoy $decoyAws"
}
Write-Output "PATH: Get-Command aws -CommandType Application finds the fake, Get-Command aws finds the decoy"

$clientDir = Join-Path $root 'scripts\client'
$waitScript = Join-Path $clientDir 'start-ec2-and-wait.ps1'
$startScript = Join-Path $clientDir 'start-ec2.ps1'
$powershell = (Get-Process -Id $PID).Path
$failures = 0

function Add-Failure {
    param([string]$Message)
    Write-Output "FAIL: $Message"
    $script:failures++
}

# The text of a file the scripts or the fake should have written, or $null when it is missing: a missing file is a
# failed check, not a throw that stops the remaining cases
function Get-FileText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return [IO.File]::ReadAllText($Path)
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
    foreach ($key in @('FAKE_STATE', 'FAKE_FAIL', 'FAKE_SSM_SEQUENCE', 'FAKE_COUNTER', 'FAKE_WARN', 'FAKE_ARGS_LOG', 'FAKE_VERSION_FAIL', 'FAKE_VERSION_STDERR', 'FAKE_VERSION_EMPTY', 'FAKE_LOOKUP_IDS', 'FAKE_SESSION_STDERR')) {
        $psi.EnvironmentVariables.Remove($key)
    }
    $psi.EnvironmentVariables['EC2WS_SSM_POLL_INTERVAL'] = '1'
    $psi.EnvironmentVariables['PATH'] = $testPath
    # If the real aws runs, it fails on the missing credentials at once instead of trying the instance metadata
    $psi.EnvironmentVariables['AWS_EC2_METADATA_DISABLED'] = 'true'
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = $Environment[$key]
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(10000)) {
        # taskkill may write to stderr (the child already gone); under Stop, 5.1 would throw on that line
        & {
            $ErrorActionPreference = 'Continue'
            & taskkill /T /F /PID $process.Id 2>&1 | Out-Null
        }
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
if ($null -eq (Get-FileText $argsLog)) {
    Add-Failure 'arguments: the fake was not called'
} else {
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
}

$awsLoginHint = "  If the AWS error above says the credentials are missing or expired, run 'aws login' and connect again."

# Warnings on stderr (each after an empty line from the fake) come out as their own lines, with no blank line and no
# RemoteException; the fake warns on the lookup, the state and the SSM check
function Test-WarningLine {
    param([string]$Label, [hashtable]$Result)
    $lines = @(($Result.Stderr -replace "`r`n", "`n").TrimEnd("`n") -split "`n")
    foreach ($what in @('lookup', 'state', 'describe-instance-information')) {
        if ($lines -notcontains "fake aws: warning from $what") {
            Add-Failure "${Label}: want the line 'fake aws: warning from $what' on stderr, got: $($Result.Stderr)"
        }
    }
    if (@($lines | Where-Object { -not $_.Trim() }).Count -ne 0 -or $Result.Stderr -match 'RemoteException') {
        Add-Failure "${Label}: want no blank line and no RemoteException on stderr, got: $($Result.Stderr)"
    }
}

# $Line is a whole line of $Text; with $WantHint the hint is the very next line, otherwise there is no hint at all.
# Never the old banner, never RemoteException
function Test-ErrorLine {
    param([string]$Label, [string]$Text, [string]$Line, [bool]$WantHint)
    $lines = @(($Text -replace "`r`n", "`n") -split "`n")
    $at = [array]::IndexOf($lines, $Line)
    if ($at -lt 0) {
        Add-Failure "${Label}: want the line '$Line', got: $Text"
    } elseif ($WantHint -and ($at + 1 -ge $lines.Count -or $lines[$at + 1] -ne $awsLoginHint)) {
        Add-Failure "${Label}: want the hint right after '$Line', got: $Text"
    }
    if (-not $WantHint -and $lines -contains $awsLoginHint) {
        Add-Failure "${Label}: want no hint, got: $Text"
    }
    if ($Text -match 'ERROR: AWS authentication failed|RemoteException') {
        Add-Failure "${Label}: want no banner and no RemoteException, got: $Text"
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
    if ($case.Warn) {
        Test-WarningLine -Label $label -Result $result
    }

    $label = "start-ec2 $($case.Name)" + $(if ($case.Warn) { ' with warnings' } else { '' })
    $result = Invoke-Case -Script $startScript -Arguments $startArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or ($result.Stdout -join "`n") -notmatch 'EC2 instance is ready') {
        Add-Failure "${label}: want rc=0 and the ready message"
    }
    if ($case.Warn) {
        Test-WarningLine -Label $label -Result $result
    }
}

# The session's stderr goes straight through (not converted): no ErrorRecord text from 5.1 around it
$result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment @{ FAKE_STATE = 'running'; FAKE_SESSION_STDERR = '1' }
Write-Case -Name 'start-ec2-and-wait session stderr' -Result $result
if ($result.TimedOut -or $result.ExitCode -ne 0 -or ($result.Stdout -join "`n") -ne 'SSH-2.0-fake' -or
    @($result.Stderr -split "`r?`n") -notcontains 'fake aws: session warning' -or $result.Stderr -match 'RemoteException|NativeCommandError|CategoryInfo') {
    Add-Failure "start-ec2-and-wait session stderr: want rc=0, stdout 'SSH-2.0-fake' alone and the line 'fake aws: session warning' as is, got stderr: $($result.Stderr)"
}

# A failed aws call stops the script at once with the reason as aws wrote it (the fake's empty stderr line dropped);
# the ProxyCommand's stdout stays empty. Lines from the fake: 'fake aws: <what> failed'
$id = 'i-0123456789abcdef0'
foreach ($case in @(
        @{ State = 'running'; Fail = 'lookup'; Line = 'Error: Failed to look up instance: fake aws: lookup failed' },
        @{ State = 'running'; Fail = 'state'; Line = 'Error: Failed to get instance state: fake aws: state failed' },
        @{ State = 'stopped'; Fail = 'start-instances'; Line = "Error: Failed to start instance ${id}: fake aws: start-instances failed" },
        @{ State = 'stopped'; Fail = 'wait-instance-running'; Line = "Error: Failed while waiting for instance $id to be running: fake aws: wait-instance-running failed" },
        @{ State = 'stopping'; Fail = 'wait-instance-stopped'; Line = "Error: Failed while waiting for instance $id to be stopped: fake aws: wait-instance-stopped failed" },
        @{ State = 'stopping'; Fail = 'start-instances'; Line = "Error: Failed to start instance ${id}: fake aws: start-instances failed" },
        @{ State = 'stopping'; Fail = 'wait-instance-running'; Line = "Error: Failed while waiting for instance $id to be running: fake aws: wait-instance-running failed" },
        @{ State = 'pending'; Fail = 'wait-instance-running'; Line = "Error: Failed while waiting for instance $id to be running: fake aws: wait-instance-running failed" },
        @{ State = 'running'; Fail = 'describe-instance-information'; Line = "Error: Failed to check the SSM Agent of ${id}: fake aws: describe-instance-information failed (3 times in a row)" })) {
    $environment = @{ FAKE_STATE = $case.State; FAKE_FAIL = $case.Fail }
    $reason = "fake aws: $($case.Fail) failed"
    # The lookup, the state, and the SSM check (failing 3 times in a row) can fail on expired credentials, so the
    # ProxyCommand adds the conditional hint after the error
    $wantHint = $case.Fail -in @('lookup', 'state', 'describe-instance-information')

    $label = "start-ec2-and-wait $($case.State), $($case.Fail) fails"
    $result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1 -or $result.Stdout.Count -ne 0 -or $result.Stderr -notmatch [regex]::Escape($reason)) {
        Add-Failure "${label}: want rc=1 within 10s, empty stdout, and '$reason' on stderr"
    }
    Test-ErrorLine -Label $label -Text $result.Stderr -Line $case.Line -WantHint $wantHint

    $label = "start-ec2 $($case.State), $($case.Fail) fails"
    $result = Invoke-Case -Script $startScript -Arguments $startArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1 -or (($result.Stdout -join "`n") + $result.Stderr) -notmatch [regex]::Escape($reason)) {
        Add-Failure "${label}: want rc=1 within 10s and '$reason'"
    }
    Test-ErrorLine -Label $label -Text ((($result.Stdout -join "`n") + "`n" + $result.Stderr)) -Line $case.Line -WantHint $false
}

# Stops that are not aws failures never add the hint
foreach ($case in @(
        @{ Name = 'two instances'; Environment = @{ FAKE_STATE = 'running'; FAKE_LOOKUP_IDS = 'i-1 i-2' }
            Line = "Error: Expected exactly one instance tagged Name=ws in ap-northeast-1, found 2: i-1 i-2. Check the instance_name in 'tofu output workstations' and re-run setup-remote-ssh if it changed." },
        @{ Name = 'unexpected state'; Environment = @{ FAKE_STATE = 'shutting-down' }; Line = 'Error: Unexpected instance state: shutting-down' })) {
    $label = "start-ec2-and-wait $($case.Name)"
    $result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment $case.Environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1) {
        Add-Failure "${label}: want rc=1 within 10s"
    }
    Test-ErrorLine -Label $label -Text $result.Stderr -Line $case.Line -WantHint $false
}

# The SSM check retries until 3 failures in a row, and an answer in between starts the count again:
# fail, fail, Online and fail, fail, None, fail, fail, Online both connect
$counter = Join-Path $work 'ssm-count'
foreach ($sequence in @('fail,fail,Online', 'fail,fail,None,fail,fail,Online')) {
    $environment = @{ FAKE_STATE = 'running'; FAKE_SSM_SEQUENCE = $sequence; FAKE_COUNTER = $counter }
    Remove-Item $counter -ErrorAction SilentlyContinue
    $result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment $environment
    Write-Case -Name "start-ec2-and-wait SSM $sequence" -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 0 -or ($result.Stdout -join "`n") -ne 'SSH-2.0-fake') {
        Add-Failure "start-ec2-and-wait SSM ${sequence}: want rc=0 and stdout 'SSH-2.0-fake' alone"
    }
    Remove-Item $counter -ErrorAction SilentlyContinue
    $result = Invoke-Case -Script $startScript -Arguments $startArgs -Environment $environment
    Write-Case -Name "start-ec2 SSM $sequence" -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        Add-Failure "start-ec2 SSM ${sequence}: want rc=0"
    }
}

# setup-remote-ssh.ps1: one auto-start script per host (ec2-workstation-proxy-<host>.ps1). A setup for another host must not
# change this host's script or its Host block, and the shared start-ec2-and-wait.ps1 of an older setup stays as it is.
# The setup copies start-ec2-and-wait.ps1 from its own folder (scripts\client) and writes only under USERPROFILE
$setupScript = Join-Path $clientDir 'setup-remote-ssh.ps1'
$profileDir = Join-Path $work 'profile'
$sshDir = Join-Path $profileDir '.ssh'
$pluginDir = Join-Path $work 'plugin'
New-Item -ItemType Directory -Path $sshDir, $pluginDir | Out-Null
[IO.File]::WriteAllText((Join-Path $pluginDir 'session-manager-plugin.cmd'), "@echo 1.2.3`r`n", [Text.Encoding]::ASCII)
$setupEnvironment = @{ FAKE_STATE = 'ec2-user'; USERPROFILE = $profileDir; PATH = "$pluginDir;$testPath" }
$oldShared = Join-Path $sshDir 'start-ec2-and-wait.ps1'
[IO.File]::WriteAllText($oldShared, "old shared script`n")
$newVersion = [IO.File]::ReadAllText($waitScript)

function Invoke-Setup {
    param([string]$Name, [string]$SshHost, [int]$WantExitCode = 0)
    $result = Invoke-Case -Script $setupScript -Arguments @('-InstanceName', "ws-$Name", '-SshHost', $SshHost, '-Region', 'ap-northeast-1') -Environment $setupEnvironment
    Write-Case -Name "setup $Name" -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne $WantExitCode) {
        Add-Failure "setup ${Name}: want rc=$WantExitCode, stderr: $($result.Stderr)"
    }
    return $result
}

# The Host block of a host in ~/.ssh/config (the Host line and the indented lines after it), with LF line endings.
# The setup writes the new block with the line endings of its own file (CRLF in a Windows checkout) and turns the rest
# of the config into LF, so the blocks are compared without CR
function Get-HostBlock {
    param([string]$SshHost)
    $config = "$(Get-FileText (Join-Path $sshDir 'config'))" -replace "`r`n", "`n"
    # The comma keeps a one-block result an array (a bare return unrolls it to a string, and [0] would be its first character)
    return ,@([regex]::Matches($config, "(?m)^Host $SshHost\n(?:   .+\n)*") | ForEach-Object { $_.Value })
}

function Get-ProxyScript {
    param([string]$SshHost)
    return Join-Path $sshDir "ec2-workstation-proxy-$SshHost.ps1"
}

# 1. alpha, given as Alpha: the name is lowercased, and the ProxyCommand runs alpha's own script without the user's profile
$result = Invoke-Setup -Name 'alpha' -SshHost 'Alpha'
$alphaScript = Get-ProxyScript 'alpha'
$wantProxy = "   ProxyCommand powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$($alphaScript -replace '\\', '/')`" %h ap-northeast-1 %p"
$alphaBlock = Get-HostBlock 'alpha'
if ((Get-FileText $alphaScript) -ne $newVersion) {
    Add-Failure "setup alpha: $alphaScript is not a copy of start-ec2-and-wait.ps1"
}
if ($alphaBlock.Count -ne 1 -or ($alphaBlock[0] -split "`n") -notcontains $wantProxy -or ($alphaBlock[0] -split "`n") -notcontains '   User ec2-user') {
    Add-Failure "setup alpha: want one Host alpha with '$wantProxy', got: $alphaBlock"
}
$output = $result.Stdout -join "`n"
if ($output -notlike "*'alpha' runs $alphaScript*" -or $output -notlike '*run this setup again for that host*') {
    Add-Failure "setup alpha: the last message does not name the script or say how to update it"
}

# 2. beta: alpha's script (an older version, marked) and the content of its Host block stay; so does the shared script
[IO.File]::AppendAllText($alphaScript, "# older alpha`r`n")
$alphaBefore = Get-FileText $alphaScript
$null = Invoke-Setup -Name 'beta' -SshHost 'beta'
$betaScript = Get-ProxyScript 'beta'
if (-not (Test-Path $betaScript) -or @(Get-HostBlock 'beta').Count -ne 1 -or (Get-HostBlock 'beta')[0] -notlike "*$($betaScript -replace '\\', '/')*") {
    Add-Failure "setup beta: want Host beta running $betaScript"
}
if ((Get-FileText $alphaScript) -ne $alphaBefore) {
    Add-Failure "setup beta: changed $alphaScript"
}
if (((Get-HostBlock 'alpha') -join '') -ne ($alphaBlock -join '')) {
    Add-Failure "setup beta: changed Host alpha: $(Get-HostBlock 'alpha')"
}
if ((Get-FileText $oldShared) -ne "old shared script`n") {
    Add-Failure 'setup beta: changed the shared start-ec2-and-wait.ps1'
}

# 3. alpha again: only alpha's script becomes the new version, and there is one Host alpha
$betaBefore = Get-FileText $betaScript
$null = Invoke-Setup -Name 'alpha-again' -SshHost 'alpha'
if ((Get-FileText $alphaScript) -ne $newVersion) {
    Add-Failure "setup alpha-again: $alphaScript is not the new version"
}
if (@(Get-HostBlock 'alpha').Count -ne 1) {
    Add-Failure "setup alpha-again: want one Host alpha, got $(@(Get-HostBlock 'alpha').Count)"
}
if ((Get-FileText $betaScript) -ne $betaBefore -or (Get-FileText $oldShared) -ne "old shared script`n") {
    Add-Failure 'setup alpha-again: changed beta or the shared script'
}

# 4. A bad -SshHost stops before anything is written or changed (..\x would name a file outside ~/.ssh, and a final
# newline would go into the file name and the Host line)
# Only USERPROFILE, where the setup writes: the fake's call log under $work changes on every run
function Get-Snapshot {
    return @(Get-ChildItem -Recurse -File $profileDir | Sort-Object FullName | ForEach-Object { "$($_.FullName)=$((Get-FileHash $_.FullName).Hash)" })
}
foreach ($badHost in @('..\x', "alpha`n")) {
    $before = Get-Snapshot
    $result = Invoke-Setup -Name 'bad-host' -SshHost $badHost -WantExitCode 1
    if ($result.Stderr -notlike '*is not a valid host name*') {
        Add-Failure "setup bad-host '$badHost': want 'is not a valid host name', got: $($result.Stderr)"
    }
    if (((Get-Snapshot) -join '|') -ne ($before -join '|')) {
        Add-Failure "setup bad-host '$badHost': files were written or changed"
    }
}

# No aws on PATH (the decoy stays): each script stops with the same three lines before it touches AWS, and start-ec2
# stops before it asks for the instance name (without arguments, its prompt would fail in -NonInteractive)
$awsMissing = @(
    'Error: AWS CLI v2 (aws) is not installed or not in PATH.',
    '  Download: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html',
    '  Note: After installation, restart VS Code or PowerShell so that PATH is reloaded.'
) -join "`n"
$noAwsPath = "$decoyDir;$env:SystemRoot\System32"

function Get-CaseOutput {
    param([hashtable]$Result)
    return (($Result.Stdout -join "`n") + "`n" + $Result.Stderr) -replace "`r`n", "`n"
}

# rc=1 within 10s, and one of $Blocks (lines joined with `n) appears as whole lines: a newline on both sides, so text
# added before the first line or after the last one fails
function Test-StopsWith {
    param([string]$Label, [hashtable]$Result, [string[]]$Blocks)
    Write-Case -Name $Label -Result $Result
    $output = Get-CaseOutput $Result
    $found = @($Blocks | Where-Object { ("`n$output`n").Contains("`n$_`n") }).Count -gt 0
    if ($Result.TimedOut -or $Result.ExitCode -ne 1 -or -not $found) {
        Add-Failure "${Label}: want rc=1 within 10s and the lines '$($Blocks[0])', got: $output"
    }
}

$result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment @{ PATH = $noAwsPath }
Test-StopsWith -Label 'start-ec2-and-wait without aws' -Result $result -Blocks $awsMissing
if (-not $result.TimedOut -and ($result.Stdout.Count -ne 0 -or $result.Stderr -match 'aws login')) {
    Add-Failure 'start-ec2-and-wait without aws: want empty stdout and no authentication guidance (aws login)'
}
Test-StopsWith -Label 'start-ec2 without aws' -Result (Invoke-Case -Script $startScript -Arguments $startArgs -Environment @{ PATH = $noAwsPath }) -Blocks $awsMissing
Test-StopsWith -Label 'start-ec2 without aws or arguments' -Result (Invoke-Case -Script $startScript -Arguments @() -Environment @{ PATH = $noAwsPath }) -Blocks $awsMissing
$before = Get-Snapshot
$result = Invoke-Case -Script $setupScript -Arguments @('-InstanceName', 'ws-noaws', '-SshHost', 'noaws', '-Region', 'ap-northeast-1') -Environment @{ USERPROFILE = $profileDir; PATH = "$pluginDir;$noAwsPath" }
Test-StopsWith -Label 'setup without aws' -Result $result -Blocks $awsMissing
if (((Get-Snapshot) -join '|') -ne ($before -join '|')) {
    Add-Failure 'setup without aws: files were written or changed'
}

# A tool whose --version fails stops the setup before it touches AWS, with the tool's path, exit code and all of its
# output (stdout and stderr, whose lines 5.1 may merge in either order; the empty stderr line is dropped)
$brokenPluginDir = Join-Path $work 'broken plugin'
New-Item -ItemType Directory -Path $brokenPluginDir | Out-Null
$brokenPlugin = Join-Path $brokenPluginDir 'session-manager-plugin.cmd'
[IO.File]::WriteAllText($brokenPlugin, (@('@echo off', 'echo fake plugin: version stdout', '>&2 echo(', '>&2 echo fake plugin: broken', 'exit /b 4') -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)
# A session-manager-plugin.exe that is not an executable: it does not start at all (no exit code)
$badExePluginDir = Join-Path $work 'bad exe plugin'
New-Item -ItemType Directory -Path $badExePluginDir | Out-Null
$badExePlugin = Join-Path $badExePluginDir 'session-manager-plugin.exe'
[IO.File]::WriteAllText($badExePlugin, "not an executable`r`n", [Text.Encoding]::ASCII)
$versionLog = Join-Path $work 'version-args.log'

function Get-VersionFailedText {
    param([string]$Label, [string]$Path, [int]$Code, [string[]]$Output)
    $head = "Error: $Label failed to run: '$Path --version' exited with code $Code."
    $tail = '  Reinstall it, or fix PATH so that a working one comes first.'
    # Each -join in parentheses: a bare ', ' after "`n" would make the separator an array
    return @(
        ((@($head) + ($Output | ForEach-Object { "    $_" }) + $tail) -join "`n"),
        ((@($head) + ($Output[1..0] | ForEach-Object { "    $_" }) + $tail) -join "`n")
    )
}

# $Blocks: the error lines as they must appear; $Pattern instead when a line is not known in full (an exception's text)
function Test-VersionFailed {
    param([string]$Name, [hashtable]$Environment, [string[]]$Blocks, [string]$Pattern)
    Remove-Item $versionLog -ErrorAction SilentlyContinue
    $before = Get-Snapshot
    $result = Invoke-Case -Script $setupScript -Arguments @('-InstanceName', "ws-$Name", '-SshHost', $Name, '-Region', 'ap-northeast-1') -Environment ($Environment + @{ USERPROFILE = $profileDir; FAKE_STATE = 'ec2-user'; FAKE_ARGS_LOG = $versionLog })
    $output = Get-CaseOutput $result
    if ($Pattern) {
        Write-Case -Name "setup $Name" -Result $result
        # One line of the OS's reason, without the script position that PowerShell's own message adds
        if ($result.TimedOut -or $result.ExitCode -ne 1 -or $output -notmatch $Pattern -or $output -match 'char:\d') {
            Add-Failure "setup ${Name}: want rc=1 within 10s and lines matching '$Pattern', got: $output"
        }
    } else {
        Test-StopsWith -Label "setup $Name" -Result $result -Blocks $Blocks
    }
    # The setup stops at its last prerequisite check, not inside the version check
    if (-not ("`n$output`n").Contains("`nPlease install the missing prerequisites and try again.`n")) {
        Add-Failure "setup ${Name}: want the line 'Please install the missing prerequisites and try again.'"
    }
    # '- OK' only for PowerShell and the other tool
    if ($output -match 'RemoteException' -or [regex]::Matches($output, '(?m) - OK$').Count -ne 2) {
        Add-Failure "setup ${Name}: want no RemoteException and '- OK' only for PowerShell and the other tool, got: $output"
    }
    $calls = @("$(Get-FileText $versionLog)" -split "`r?`n" | Where-Object { $_.Trim() })
    if (($calls -join '|') -ne '--version') {
        Add-Failure "setup ${Name}: want the fake aws to receive only --version, got: $($calls -join ' | ')"
    }
    if (((Get-Snapshot) -join '|') -ne ($before -join '|')) {
        Add-Failure "setup ${Name}: files were written or changed"
    }
}

Test-VersionFailed -Name 'aws-version-fails' -Environment @{ PATH = "$pluginDir;$testPath"; FAKE_VERSION_FAIL = '1' } `
    -Blocks (Get-VersionFailedText -Label 'AWS CLI v2 (aws)' -Path $fakeAws -Code 3 -Output @('fake aws: version stdout', 'fake aws: version failed'))
Test-VersionFailed -Name 'plugin-version-fails' -Environment @{ PATH = "$brokenPluginDir;$testPath" } `
    -Blocks (Get-VersionFailedText -Label 'Session Manager Plugin (session-manager-plugin)' -Path $brokenPlugin -Code 4 -Output @('fake plugin: version stdout', 'fake plugin: broken'))
Test-VersionFailed -Name 'plugin-does-not-start' -Environment @{ PATH = "$badExePluginDir;$testPath" } `
    -Pattern ("(?m)^Error: Session Manager Plugin \(session-manager-plugin\) failed to run: '" + [regex]::Escape($badExePlugin) + " --version' could not start\.\n    \S.*\n  Reinstall it, or fix PATH so that a working one comes first\.$")

# A tool that prints its version on stderr and exits 0 (AWS CLI v1 does) passes: only the exit code decides
$result = Invoke-Case -Script $setupScript -Arguments @('-InstanceName', 'ws-gamma', '-SshHost', 'gamma', '-Region', 'ap-northeast-1') -Environment ($setupEnvironment + @{ FAKE_VERSION_STDERR = '1' })
Write-Case -Name 'setup version on stderr' -Result $result
$output = Get-CaseOutput $result
if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not ("`n$output`n").Contains("`n  aws-cli/1.0.0 fake - OK`n") -or $output -match 'RemoteException') {
    Add-Failure "setup version on stderr: want rc=0, the line '  aws-cli/1.0.0 fake - OK' and no RemoteException, got: $output"
}

# A tool that prints nothing and exits 0 passes too (an empty version is not an error)
$result = Invoke-Case -Script $setupScript -Arguments @('-InstanceName', 'ws-delta', '-SshHost', 'delta', '-Region', 'ap-northeast-1') -Environment ($setupEnvironment + @{ FAKE_VERSION_EMPTY = '1' })
Write-Case -Name 'setup empty version' -Result $result
$output = Get-CaseOutput $result
if ($result.TimedOut -or $result.ExitCode -ne 0 -or -not ("`n$output`n").Contains("`n   - OK`n")) {
    Add-Failure "setup empty version: want rc=0 and the line '   - OK', got: $output"
}

} finally {
    Remove-Item -Recurse -Force $work
}
if ($failures -ne 0) {
    Write-Output "$failures check(s) failed"
    exit 1
}
Write-Output 'all checks passed'
