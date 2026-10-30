<#
.SYNOPSIS
    EC2インスタンスの状態を確認し、停止中なら起動して待機するスクリプト
.DESCRIPTION
    VS Code Remote-SSHのProxyCommandから呼び出され、
    EC2インスタンスが起動していない場合は自動的に起動し、
    起動完了まで待機してからSSMセッションを開始します。
.PARAMETER InstanceName
    EC2インスタンスの Name タグ（AMI 更新でインスタンス ID が変わるため ID ではなく Name タグで指定する）
.PARAMETER Region
    AWSリージョン
.PARAMETER PortNumber
    SSHポート番号（通常は22）
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$InstanceName,

    [Parameter(Mandatory=$true)]
    [string]$Region,

    [Parameter(Mandatory=$true)]
    [string]$PortNumber
)

$ErrorActionPreference = "Continue"

# AWS CLI path
$awsCli = (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path

# stderr writer for ProxyCommand environment (UTF8 without BOM)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$stderrWriter = [System.IO.StreamWriter]::new([Console]::OpenStandardError(), $utf8NoBom)
$stderrWriter.AutoFlush = $true
$stderrWriter.NewLine = "`n"

function Write-Stderr {
    param([string]$Message)
    $stderrWriter.WriteLine($Message)
}

# 下の try の外で止める (catch は条件つきの認証の案内を付けるが、aws が無いのはそれと関係ない)
if (-not $awsCli) {
    Write-Stderr "Error: AWS CLI v2 (aws) is not installed or not in PATH."
    Write-Stderr "  Download: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    Write-Stderr "  Note: After installation, restart VS Code or PowerShell so that PATH is reloaded."
    exit 1
}

function Write-ScriptLog {
    param([string]$Message)
    Write-Stderr "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# 名前の引き・状態の引き・SSM の問い合わせ (続けて 3 回) の失敗の文の後に付ける。理由は aws の文にしか無いので、言い切らない
$awsLoginHint = "  If the AWS error above says the credentials are missing or expired, run 'aws login' and connect again."

# aws を呼び、成功なら stdout の行だけを返す。失敗 (rc≠0) なら stderr の行を付けて throw する。
# stdout は SSH の通信路なので、呼ぶ所は戻り値を必ず受けるか捨てる。成功のときの stderr の警告は stderr にそのまま流す
function Invoke-AwsCli {
    param(
        [string]$Description,
        [string[]]$Arguments
    )
    # Windows PowerShell 5.1 は、Stop のもとでは native のコマンドの stderr の 1 行目で throw し、$LASTEXITCODE を見る所に届かない
    $ErrorActionPreference = 'Continue'
    $all = & $awsCli @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object {
            # "$_" would turn an empty stderr line into System.Management.Automation.RemoteException
            if ($_.TargetObject -is [string]) { $_.TargetObject } else { $_.Exception.Message }
        } | Where-Object { $_.Trim() })
    $stdout = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($exitCode -ne 0) {
        throw "${Description}: $($stderr -join ' ')"
    }
    foreach ($line in $stderr) {
        Write-Stderr $line
    }
    return $stdout
}

function Wait-SSMAgentReady {
    param(
        [string]$InstanceId,
        [string]$Region,
        [int]$MaxRetries = 60,
        [int]$RetryIntervalSeconds = 5,
        [int]$MaxFailures = 3
    )

    # EC2WS_SSM_POLL_INTERVAL はテストのための環境変数 (問い合わせの間隔を縮める)。1〜9999 の整数のときだけ使い、
    # ほかの値は既定のまま (ProxyCommand が誤った値を読んで止まらないように)
    if ($env:EC2WS_SSM_POLL_INTERVAL -match '^[1-9][0-9]{0,3}$') {
        $RetryIntervalSeconds = [int]$env:EC2WS_SSM_POLL_INTERVAL
    }

    Write-ScriptLog "Waiting for SSM Agent to be ready..."

    # 問い合わせの一時的な失敗 (スロットリング・ネットワークの断) は待って問い合わせ直し、続けて $MaxFailures 回失敗したら、
    # 認証の切れなど待っても直らないものとして止まる (成功を 1 回挟めば数え直す)
    $failures = 0
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $pingStatus = Invoke-AwsCli -Description "Failed to check the SSM Agent of $InstanceId" -Arguments @(
                'ssm', 'describe-instance-information', '--region', $Region,
                '--filters', "Key=InstanceIds,Values=$InstanceId",
                '--query', 'InstanceInformationList[0].PingStatus', '--output', 'text')
        } catch {
            $failures++
            if ($failures -ge $MaxFailures) {
                throw "$_ ($MaxFailures times in a row)`n$awsLoginHint"
            }
            Write-ScriptLog "Failed to check the SSM Agent (attempt $i/$MaxRetries, failure $failures/$MaxFailures), retrying: $_"
            Start-Sleep -Seconds $RetryIntervalSeconds
            continue
        }
        $failures = 0

        if ($pingStatus -eq "Online") {
            Write-ScriptLog "SSM Agent is online"
            return
        }

        Write-ScriptLog "SSM Agent not ready yet (attempt $i/$MaxRetries, status: $pingStatus)"
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    throw "Timeout waiting for SSM Agent to become ready after $($MaxRetries * $RetryIntervalSeconds) seconds"
}

function Invoke-StartInstance {
    param([string]$InstanceId, [string]$Region)
    Write-ScriptLog "Starting instance $InstanceId..."
    try {
        $null = Invoke-AwsCli -Description "Failed to start instance $InstanceId" -Arguments @(
            'ec2', 'start-instances', '--instance-ids', $InstanceId, '--region', $Region)
    } catch {
        throw "$_`n$awsLoginHint"
    }
}

function Wait-InstanceState {
    param([string]$InstanceId, [string]$Region, [string]$State)
    $null = Invoke-AwsCli -Description "Failed while waiting for instance $InstanceId to be $State" -Arguments @(
        'ec2', 'wait', "instance-$State", '--instance-ids', $InstanceId, '--region', $Region)
}

try {
    # Name タグからインスタンス ID を引く
    try {
        $instanceIds = Invoke-AwsCli -Description "Failed to look up instance" -Arguments @(
            'ec2', 'describe-instances', '--region', $Region,
            '--filters', "Name=tag:Name,Values=$InstanceName", 'Name=instance-state-name,Values=pending,running,stopping,stopped',
            '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text')
    } catch {
        throw
    }

    $instanceIdList = @("$instanceIds" -split '\s+' | Where-Object { $_ })
    if ($instanceIdList.Count -ne 1) {
        throw "Expected exactly one instance tagged Name=$InstanceName in $Region, found $($instanceIdList.Count): $instanceIds. Check the instance_name in 'tofu output workstations' and re-run setup-remote-ssh if it changed."
    }
    $InstanceId = $instanceIdList[0]

    # EC2インスタンスの状態を確認
    try {
        $state = Invoke-AwsCli -Description "Failed to get instance state" -Arguments @(
            'ec2', 'describe-instances', '--instance-ids', $InstanceId, '--region', $Region,
            '--query', 'Reservations[0].Instances[0].State.Name', '--output', 'text')
        if ($state -notin @('stopped', 'stopping', 'pending', 'running')) { throw "Unexpected instance state: $state" }
    } catch {
        throw "$_`n$awsLoginHint"
    }

    Write-ScriptLog "Instance $InstanceId state: $state"

    if ($state -eq "stopped") {
        Invoke-StartInstance -InstanceId $InstanceId -Region $Region
        Write-ScriptLog "Waiting for instance to be running..."
        Wait-InstanceState -InstanceId $InstanceId -Region $Region -State running
    }
    elseif ($state -eq "stopping") {
        Write-ScriptLog "Instance is stopping, waiting for it to stop..."
        Wait-InstanceState -InstanceId $InstanceId -Region $Region -State stopped
        Invoke-StartInstance -InstanceId $InstanceId -Region $Region
        Write-ScriptLog "Waiting for instance to be running..."
        Wait-InstanceState -InstanceId $InstanceId -Region $Region -State running
    }
    elseif ($state -eq "pending") {
        Write-ScriptLog "Instance is starting, waiting..."
        Wait-InstanceState -InstanceId $InstanceId -Region $Region -State running
    }
    elseif ($state -eq "running") {
        Write-ScriptLog "Instance is already running, checking SSM Agent..."
    }
    else {
        throw "Unexpected instance state: $state"
    }

    # 起動した後も、既に起動中でも、SSM Agent が接続されていない可能性があるため確認
    Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region
} catch {
    Write-Stderr "Error: $_"
    exit 1
}

# SSMセッションを開始する。stdout が SSH の通信路そのものなので、Invoke-AwsCli に通さず直に呼ぶ (全部を受けてから返すと通信が流れない)
& $awsCli ssm start-session `
    --region $Region `
    --target $InstanceId `
    --document-name AWS-StartSSHSession `
    --parameters "portNumber=$PortNumber"
exit $LASTEXITCODE
