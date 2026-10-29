<#
.SYNOPSIS
    Checks start-ec2-and-wait.ps1, start-ec2.ps1 and setup-remote-ssh.ps1 with a fake AWS CLI.
.DESCRIPTION
    Each script is copied to a temp directory with its one $awsCli line pointed at a fake aws.cmd, and run in a
    child powershell.exe (the same one that runs this test). start-ec2-and-wait.ps1 runs as the SSH ProxyCommand,
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
$utf8Bom = [Text.UTF8Encoding]::new($true)

# The fake dispatches on the first three arguments only (%1 %2 %3), so the characters in --query and --filters
# are never parsed by cmd. It logs the whole command line to FAKE_ARGS_LOG to show how the arguments arrive.
$fakeAws = Join-Path $work 'aws.cmd'
$fakeLines = @(
    '@echo off',
    'setlocal',
    'if defined FAKE_ARGS_LOG >>"%FAKE_ARGS_LOG%" echo(%*',
    'if "%~1"=="--version" (echo aws-cli/2.0.0 fake& exit /b 0)',
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
    '>&2 echo fake aws: %what% failed',
    'exit /b 1',
    ':succeed',
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
    'if "%what%"=="describe-key-pairs" echo key-0123456789abcdef0',
    'if "%what%"=="get-parameter" echo FAKE PRIVATE KEY',
    'exit /b 0'
)
[IO.File]::WriteAllText($fakeAws, ($fakeLines -join "`r`n") + "`r`n", [Text.Encoding]::ASCII)

$awsCliLine = '$awsCli = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"'

# Copy a script with its $awsCli line pointed at the fake, keeping the BOM (5.1 reads a file without one in the ANSI code page)
function Copy-ScriptWithFakeCli {
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

$waitScript = Copy-ScriptWithFakeCli 'start-ec2-and-wait.ps1'
$startScript = Copy-ScriptWithFakeCli 'start-ec2.ps1'
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
    foreach ($key in @('FAKE_STATE', 'FAKE_FAIL', 'FAKE_SSM_SEQUENCE', 'FAKE_COUNTER', 'FAKE_WARN', 'FAKE_ARGS_LOG')) {
        $psi.EnvironmentVariables.Remove($key)
    }
    $psi.EnvironmentVariables['EC2WS_SSM_POLL_INTERVAL'] = '1'
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
        @{ State = 'running'; Fail = 'lookup' },
        @{ State = 'running'; Fail = 'state' },
        @{ State = 'stopped'; Fail = 'start-instances' },
        @{ State = 'stopped'; Fail = 'wait-instance-running' },
        @{ State = 'stopping'; Fail = 'wait-instance-stopped' },
        @{ State = 'stopping'; Fail = 'start-instances' },
        @{ State = 'stopping'; Fail = 'wait-instance-running' },
        @{ State = 'pending'; Fail = 'wait-instance-running' },
        @{ State = 'running'; Fail = 'describe-instance-information' })) {
    $environment = @{ FAKE_STATE = $case.State; FAKE_FAIL = $case.Fail }
    $reason = "fake aws: $($case.Fail) failed"
    # The lookup, the state, and the SSM check (failing 3 times in a row) can fail on expired credentials
    $wantAuth = $case.Fail -in @('lookup', 'state', 'describe-instance-information')

    $label = "start-ec2-and-wait $($case.State), $($case.Fail) fails"
    $result = Invoke-Case -Script $waitScript -Arguments $waitArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1 -or $result.Stdout.Count -ne 0 -or $result.Stderr -notmatch [regex]::Escape($reason)) {
        Add-Failure "${label}: want rc=1 within 10s, empty stdout, and '$reason' on stderr"
    }
    if ($wantAuth -and -not $result.TimedOut -and $result.Stderr -notmatch 'aws login') {
        Add-Failure "${label}: want the authentication guidance (aws login) on stderr"
    }

    $label = "start-ec2 $($case.State), $($case.Fail) fails"
    $result = Invoke-Case -Script $startScript -Arguments $startArgs -Environment $environment
    Write-Case -Name $label -Result $result
    if ($result.TimedOut -or $result.ExitCode -ne 1 -or (($result.Stdout -join "`n") + $result.Stderr) -notmatch [regex]::Escape($reason)) {
        Add-Failure "${label}: want rc=1 within 10s and '$reason'"
    }
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
# The setup copies start-ec2-and-wait.ps1 from its own folder, which is $work (already pointed at the fake)
$setupScript = Copy-ScriptWithFakeCli 'setup-remote-ssh.ps1'
$profileDir = Join-Path $work 'profile'
$sshDir = Join-Path $profileDir '.ssh'
$pluginDir = Join-Path $work 'plugin'
New-Item -ItemType Directory -Path $sshDir, $pluginDir | Out-Null
[IO.File]::WriteAllText((Join-Path $pluginDir 'session-manager-plugin.cmd'), "@echo 1.2.3`r`n", [Text.Encoding]::ASCII)
$setupEnvironment = @{ FAKE_STATE = 'ec2-user'; USERPROFILE = $profileDir; PATH = "$pluginDir;$env:PATH" }
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

# The Host block of a host in ~/.ssh/config (the Host line and the indented lines after it)
function Get-HostBlock {
    param([string]$SshHost)
    $config = [IO.File]::ReadAllText((Join-Path $sshDir 'config'))
    return @([regex]::Matches($config, "(?m)^Host $SshHost\n(?:   .+\n)*") | ForEach-Object { $_.Value })
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
if (-not (Test-Path $alphaScript) -or [IO.File]::ReadAllText($alphaScript) -ne $newVersion) {
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
$alphaBefore = [IO.File]::ReadAllText($alphaScript)
$null = Invoke-Setup -Name 'beta' -SshHost 'beta'
$betaScript = Get-ProxyScript 'beta'
if (-not (Test-Path $betaScript) -or @(Get-HostBlock 'beta').Count -ne 1 -or (Get-HostBlock 'beta')[0] -notlike "*$($betaScript -replace '\\', '/')*") {
    Add-Failure "setup beta: want Host beta running $betaScript"
}
if ([IO.File]::ReadAllText($alphaScript) -ne $alphaBefore) {
    Add-Failure "setup beta: changed $alphaScript"
}
if (((Get-HostBlock 'alpha') -join '') -ne ($alphaBlock -join '')) {
    Add-Failure "setup beta: changed Host alpha: $(Get-HostBlock 'alpha')"
}
if ([IO.File]::ReadAllText($oldShared) -ne "old shared script`n") {
    Add-Failure 'setup beta: changed the shared start-ec2-and-wait.ps1'
}

# 3. alpha again: only alpha's script becomes the new version, and there is one Host alpha
$betaBefore = [IO.File]::ReadAllText($betaScript)
$null = Invoke-Setup -Name 'alpha-again' -SshHost 'alpha'
if ([IO.File]::ReadAllText($alphaScript) -ne $newVersion) {
    Add-Failure "setup alpha-again: $alphaScript is not the new version"
}
if (@(Get-HostBlock 'alpha').Count -ne 1) {
    Add-Failure "setup alpha-again: want one Host alpha, got $(@(Get-HostBlock 'alpha').Count)"
}
if ([IO.File]::ReadAllText($betaScript) -ne $betaBefore -or [IO.File]::ReadAllText($oldShared) -ne "old shared script`n") {
    Add-Failure 'setup alpha-again: changed beta or the shared script'
}

# 4. A bad -SshHost stops before anything is written (it would name a file outside ~/.ssh)
$before = @(Get-ChildItem -Recurse -Name $profileDir, $work | Sort-Object)
$result = Invoke-Setup -Name 'bad-host' -SshHost '..\x' -WantExitCode 1
if ($result.Stderr -notlike '*is not a valid host name*') {
    Add-Failure "setup bad-host: want 'is not a valid host name', got: $($result.Stderr)"
}
if ((@(Get-ChildItem -Recurse -Name $profileDir, $work | Sort-Object) -join '|') -ne ($before -join '|')) {
    Add-Failure 'setup bad-host: files were written'
}

} finally {
    Remove-Item -Recurse -Force $work
}
if ($failures -ne 0) {
    Write-Output "$failures check(s) failed"
    exit 1
}
Write-Output 'all checks passed'
