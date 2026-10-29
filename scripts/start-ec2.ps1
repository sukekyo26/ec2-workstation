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

    throw "Timeout waiting for SSM Agent to become ready after $($MaxRetries * $RetryIntervalSeconds) seconds"
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
    $instanceIds = & $awsCli ec2 describe-instances `
        --region $Region `
        --filters "Name=tag:Name,Values=$InstanceName" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
        --query "Reservations[].Instances[].InstanceId" `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to look up instance: $instanceIds"
    }

    $instanceIdList = @("$instanceIds" -split '\s+' | Where-Object { $_ })
    if ($instanceIdList.Count -ne 1) {
        throw "Expected exactly one instance tagged Name=$InstanceName in $Region, found $($instanceIdList.Count): $instanceIds. Check the instance_name in 'tofu output workstations'."
    }
    $InstanceId = $instanceIdList[0]

    # EC2インスタンスの状態を確認
    $state = & $awsCli ec2 describe-instances `
        --instance-ids $InstanceId `
        --region $Region `
        --query "Reservations[0].Instances[0].State.Name" `
        --output text 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get instance state: $state"
    }

    Write-ScriptLog "Instance $InstanceId state: $state"

    # インスタンスが停止中の場合は起動
    if ($state -eq "stopped") {
        Write-ScriptLog "Starting instance $InstanceId..."

        $result = & $awsCli ec2 start-instances `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start instance: $result"
        }

        Write-ScriptLog "Waiting for instance to be running..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Timeout waiting for instance to start"
        }

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-ScriptLog "Instance is now running and ready for SSH connection"
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

        Write-ScriptLog "Instance is now running and ready for SSH connection"
    }
    elseif ($state -eq "pending") {
        Write-ScriptLog "Instance is starting, waiting..."

        & $awsCli ec2 wait instance-running `
            --instance-ids $InstanceId `
            --region $Region 2>&1

        # SSM Agentが接続されるまで待機
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region

        Write-ScriptLog "Instance is now running and ready for SSH connection"
    }
    elseif ($state -eq "running") {
        Write-ScriptLog "Instance is already running, checking SSM Agent..."
        # 既に起動中でもSSM Agentが接続されていない可能性があるため確認
        Wait-SSMAgentReady -InstanceId $InstanceId -Region $Region
        Write-ScriptLog "Instance is ready for SSH connection"
    }
    else {
        throw "Unexpected instance state: $state"
    }

    Write-Host "`n✓ EC2 instance is ready!" -ForegroundColor Green
    Write-Host "You can now connect using VS Code Remote-SSH." -ForegroundColor Green

} catch {
    Write-Host "`nError: $_" -ForegroundColor Red
    exit 1
}
