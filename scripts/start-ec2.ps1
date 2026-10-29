<#
.SYNOPSIS
    EC2インスタンスを起動してSSM Agent接続完了まで待機するスクリプト
.DESCRIPTION
    EC2インスタンスが停止中の場合は起動し、
    SSM Agentの接続完了まで待機してから終了します。
    VS Code Remote-SSH接続前に手動で実行します。
.PARAMETER InstanceName
    EC2インスタンスの Name タグ（AMI 更新でインスタンス ID が変わるため ID ではなく Name タグで指定する）
.PARAMETER Region
    AWSリージョン
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$InstanceName,

    [Parameter(Mandatory=$false)]
    [string]$Region
)

$ErrorActionPreference = "Stop"

# AWS CLI path
$awsCli = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"

function Write-ScriptLog {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

# aws を呼び、成功なら stdout の行だけを返す。失敗 (rc≠0) なら stderr の行を付けて throw する。
# 成功のときの stderr の警告は、ID や状態に混ぜずに stderr にそのまま流す
function Invoke-Aws {
    param(
        [string]$Description,
        [string[]]$Arguments
    )
    # Windows PowerShell 5.1 は、Stop のもとでは native のコマンドの stderr の 1 行目で throw する (成功のときの警告でも止まる)
    $ErrorActionPreference = 'Continue'
    $all = & $awsCli @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $stdout = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    if ($exitCode -ne 0) {
        throw "${Description}: $($stderr -join ' ')"
    }
    foreach ($line in $stderr) {
        [Console]::Error.WriteLine($line)
    }
    return $stdout
}

function Wait-SSMAgentReady {
    param(
        [string]$InstanceId,
        [string]$Region,
        [int]$MaxRetries = 60,
        [int]$RetryIntervalSeconds = 5
    )

    Write-ScriptLog "Waiting for SSM Agent to be ready..."

    for ($i = 1; $i -le $MaxRetries; $i++) {
        # 問い合わせの失敗 (認証の切れなど) は待っても直らないので、Invoke-Aws の throw ですぐ止まる
        $pingStatus = Invoke-Aws -Description "Failed to check the SSM Agent of $InstanceId" -Arguments @(
            'ssm', 'describe-instance-information', '--region', $Region,
            '--filters', "Key=InstanceIds,Values=$InstanceId",
            '--query', 'InstanceInformationList[0].PingStatus', '--output', 'text')

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
    $null = Invoke-Aws -Description "Failed to start instance $InstanceId" -Arguments @(
        'ec2', 'start-instances', '--instance-ids', $InstanceId, '--region', $Region)
}

function Wait-InstanceState {
    param([string]$InstanceId, [string]$Region, [string]$State)
    $null = Invoke-Aws -Description "Failed while waiting for instance $InstanceId to be $State" -Arguments @(
        'ec2', 'wait', "instance-$State", '--instance-ids', $InstanceId, '--region', $Region)
}

try {
    # ============================================
    # Prompt for EC2 Instance Name tag
    # ============================================
    if ([string]::IsNullOrEmpty($InstanceName)) {
        do {
            $InstanceName = Read-Host "Enter EC2 instance Name tag (instance_name in 'tofu output workstations')"

            if ([string]::IsNullOrEmpty($InstanceName)) {
                Write-Host "Error: Instance Name tag is required." -ForegroundColor Red
                continue
            }

            break
        } while ($true)
    }

    # ============================================
    # Prompt for AWS Region if not provided
    # ============================================
    if ([string]::IsNullOrEmpty($Region)) {
        $answer = Read-Host "Enter AWS Region [ap-northeast-1]"
        $Region = if ([string]::IsNullOrWhiteSpace($answer)) { "ap-northeast-1" } else { $answer }
    }

    Write-ScriptLog "Checking EC2 instance state..."

    # Name タグからインスタンス ID を引く (AMI 更新のたびにインスタンスが作り直されて ID が変わるため)
    $instanceIds = Invoke-Aws -Description "Failed to look up instance" -Arguments @(
        'ec2', 'describe-instances', '--region', $Region,
        '--filters', "Name=tag:Name,Values=$InstanceName", 'Name=instance-state-name,Values=pending,running,stopping,stopped',
        '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text')

    $instanceIdList = @("$instanceIds" -split '\s+' | Where-Object { $_ })
    if ($instanceIdList.Count -ne 1) {
        throw "Expected exactly one instance tagged Name=$InstanceName in $Region, found $($instanceIdList.Count): $instanceIds. Check the instance_name in 'tofu output workstations'."
    }
    $InstanceId = $instanceIdList[0]

    # EC2インスタンスの状態を確認
    $state = Invoke-Aws -Description "Failed to get instance state" -Arguments @(
        'ec2', 'describe-instances', '--instance-ids', $InstanceId, '--region', $Region,
        '--query', 'Reservations[0].Instances[0].State.Name', '--output', 'text')

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
    Write-ScriptLog "Instance is ready for SSH connection"

    Write-Host "`n✓ EC2 instance is ready!" -ForegroundColor Green
    Write-Host "You can now connect using VS Code Remote-SSH." -ForegroundColor Green

} catch {
    Write-Host "`nError: $_" -ForegroundColor Red
    exit 1
}
