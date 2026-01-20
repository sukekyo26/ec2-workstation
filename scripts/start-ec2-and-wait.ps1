<#
.SYNOPSIS
    EC2インスタンスの状態を確認し、停止中なら起動して待機するスクリプト
.DESCRIPTION
    VS Code Remote-SSHのProxyCommandから呼び出され、
    EC2インスタンスが起動していない場合は自動的に起動し、
    起動完了まで待機してからSSMセッションを開始します。
.PARAMETER InstanceId
    EC2インスタンスID
.PARAMETER Region
    AWSリージョン
.PARAMETER PortNumber
    SSHポート番号（通常は22）
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$InstanceId,

    [Parameter(Mandatory=$true)]
    [string]$Region,

    [Parameter(Mandatory=$true)]
    [string]$PortNumber
)

$ErrorActionPreference = "Stop"

# AWS CLI path
$awsCli = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan | Out-Null
    [Console]::Error.WriteLine("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message")
}

function Wait-SSMAgentReady {
    param(
        [string]$InstanceId,
        [string]$Region,
        [int]$MaxRetries = 60,
        [int]$RetryIntervalSeconds = 5
    )

    Write-Log "Waiting for SSM Agent to be ready..."

    for ($i = 1; $i -le $MaxRetries; $i++) {
        $pingStatus = & $awsCli ssm describe-instance-information `
            --region $Region `
            --filters "Key=InstanceIds,Values=$InstanceId" `
            --query "InstanceInformationList[0].PingStatus" `
            --output text 2>&1

        if ($pingStatus -eq "Online") {
            Write-Log "SSM Agent is online"
            return $true
        }

        Write-Log "SSM Agent not ready yet (attempt $i/$MaxRetries, status: $pingStatus)"
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    throw "Timeout waiting for SSM Agent to become ready after $($MaxRetries * $RetryIntervalSeconds) seconds"
}

try {
    # EC2インスタンスの状態を確認
    $state = & $awsCli ec2 describe-instances `
        --instance-ids $InstanceId `
        --region $Region `
        --query "Reservations[0].Instances[0].State.Name" `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get instance state: $state"
    }

    Write-Log "Instance $InstanceId state: $state"

    # インスタンスが停止中の場合は起動
    if ($state -eq "stopped") {
        Write-Log "Starting instance $InstanceId..."

        $result = & $awsCli ec2 start-instances `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start instance: $result"
        }

        Write-Log "Waiting for instance to be running..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Timeout waiting for instance to start"
        }

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-Log "Instance is now running"
    }
    elseif ($state -eq "stopping") {
        Write-Log "Instance is stopping, waiting for it to stop..."

        & $awsCli ec2 wait instance-stopped `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        Write-Log "Starting instance $InstanceId..."

        & $awsCli ec2 start-instances `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        Write-Log "Waiting for instance to be running..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-Log "Instance is now running"
    }
    elseif ($state -eq "pending") {
        Write-Log "Instance is starting, waiting..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-Log "Instance is now running"
    }
    elseif ($state -eq "running") {
        Write-Log "Instance is already running, checking SSM Agent..."
        # 既に起動中でもSSM Agentが接続されていない可能性があるため確認
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region
    }

    # SSMセッションを開始
    & $awsCli ssm start-session `
        --region $Region `
        --target $InstanceId `
        --document-name AWS-StartSSHSession `
        --parameters "portNumber=$PortNumber"

} catch {
    [Console]::Error.WriteLine("Error: $_")
    exit 1
}
