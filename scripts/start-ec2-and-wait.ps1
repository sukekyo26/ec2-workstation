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
$awsCli = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"

# stderr writer for ProxyCommand environment (UTF8 without BOM)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$stderrWriter = [System.IO.StreamWriter]::new([Console]::OpenStandardError(), $utf8NoBom)
$stderrWriter.AutoFlush = $true
$stderrWriter.NewLine = "`n"

function Write-Stderr {
    param([string]$Message)
    $stderrWriter.WriteLine($Message)
}

function Write-ScriptLog {
    param([string]$Message)
    Write-Stderr "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Write-AwsAuthenticationError {
    Write-Stderr ""
    Write-Stderr "============================================"
    Write-Stderr "ERROR: AWS authentication failed"
    Write-Stderr "============================================"
    Write-Stderr ""
    Write-Stderr "Your AWS credentials may be expired or not configured."
    Write-Stderr ""
    Write-Stderr "Please run the following command to authenticate:"
    Write-Stderr ""
    Write-Stderr "    aws login"
    Write-Stderr ""
    Write-Stderr "Then try connecting again."
    Write-Stderr "============================================"
    Write-Stderr ""
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
        $pingStatus = & $awsCli ssm describe-instance-information `
            --region $Region `
            --filters "Key=InstanceIds,Values=$InstanceId" `
            --query "InstanceInformationList[0].PingStatus" `
            --output text 2>&1

        if ($pingStatus -eq "Online") {
            Write-ScriptLog "SSM Agent is online"
            return $true
        }

        Write-ScriptLog "SSM Agent not ready yet (attempt $i/$MaxRetries, status: $pingStatus)"
        Start-Sleep -Seconds $RetryIntervalSeconds
    }

    Write-Stderr "Timeout waiting for SSM Agent to become ready after $($MaxRetries * $RetryIntervalSeconds) seconds"
    exit 1
}

try {
    # Name タグからインスタンス ID を引く
    $instanceIds = & $awsCli ec2 describe-instances `
        --region $Region `
        --filters "Name=tag:Name,Values=$InstanceName" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[].Instances[].InstanceId" `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        # 認証エラーの可能性があるためメッセージを表示
        Write-AwsAuthenticationError
        Write-Stderr "Failed to look up instance: $instanceIds"
        exit 1
    }

    $instanceIdList = @("$instanceIds" -split '\s+' | Where-Object { $_ })
    if ($instanceIdList.Count -ne 1) {
        Write-Stderr "Expected exactly one instance tagged Name=$InstanceName in $Region, found $($instanceIdList.Count): $instanceIds"
        Write-Stderr "Check the instance_name in 'tofu output workstations' and re-run setup-remote-ssh if it changed."
        exit 1
    }
    $InstanceId = $instanceIdList[0]

    # EC2インスタンスの状態を確認
    $state = & $awsCli ec2 describe-instances `
        --instance-ids $InstanceId `
        --region $Region `
        --query "Reservations[0].Instances[0].State.Name" `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        # 認証エラーの可能性があるためメッセージを表示
        Write-AwsAuthenticationError
        Write-Stderr "Failed to get instance state: $state"
        exit 1
    }

    Write-ScriptLog "Instance $InstanceId state: $state"

    # インスタンスが停止中の場合は起動
    if ($state -eq "stopped") {
        Write-ScriptLog "Starting instance $InstanceId..."

        $result = & $awsCli ec2 start-instances `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Stderr "Failed to start instance: $result"
            exit 1
        }

        Write-ScriptLog "Waiting for instance to be running..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Stderr "Timeout waiting for instance to start"
            exit 1
        }

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-ScriptLog "Instance is now running"
    }
    elseif ($state -eq "stopping") {
        Write-ScriptLog "Instance is stopping, waiting for it to stop..."

        & $awsCli ec2 wait instance-stopped `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        Write-ScriptLog "Starting instance $InstanceId..."

        & $awsCli ec2 start-instances `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        Write-ScriptLog "Waiting for instance to be running..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-ScriptLog "Instance is now running"
    }
    elseif ($state -eq "pending") {
        Write-ScriptLog "Instance is starting, waiting..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-ScriptLog "Instance is now running"
    }
    elseif ($state -eq "running") {
        Write-ScriptLog "Instance is already running, checking SSM Agent..."
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
    Write-Stderr "Error: $_"
    exit 1
}

Write-Output 'a' && Write-Output 'b'
