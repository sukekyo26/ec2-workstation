param(
    [Parameter(Mandatory=$false)]
    [string]$InstanceName,

    [Parameter(Mandatory=$false)]
    [string]$SshHost,

    [Parameter(Mandatory=$false)]
    [string]$Region
)

# ============================================
# Prerequisites Check
# ============================================
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

$hasError = $false

# Check PowerShell version
Write-Host "  PowerShell $($PSVersionTable.PSVersion) - OK" -ForegroundColor Green

# Check AWS CLI v2
$awsCliPath = "C:\Program Files\Amazon\AWSCLIV2\aws.exe"
if (-not (Test-Path $awsCliPath)) {
    Write-Host "Error: AWS CLI v2 is not installed." -ForegroundColor Red
    Write-Host "  Download: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" -ForegroundColor Yellow
    $hasError = $true
} else {
    $awsVersion = & $awsCliPath --version 2>&1
    Write-Host "  $awsVersion - OK" -ForegroundColor Green
}

# Check Session Manager Plugin (must be in PATH for AWS CLI to use it)
try {
    $ssmVersion = & session-manager-plugin --version 2>&1
    Write-Host "  Session Manager Plugin $ssmVersion - OK" -ForegroundColor Green
} catch {
    Write-Host "Error: Session Manager Plugin is not installed or not in PATH." -ForegroundColor Red
    Write-Host "  Download: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" -ForegroundColor Yellow
    Write-Host "  Note: After installation, you may need to restart PowerShell or add the plugin to PATH." -ForegroundColor Yellow
    $hasError = $true
}

# Exit if any prerequisite is missing
if ($hasError) {
    Write-Host "`nPlease install the missing prerequisites and try again." -ForegroundColor Red
    exit 1
}

Write-Host ""

# ============================================
# Prompt for EC2 Instance Name tag
# ============================================
# AMI 更新のたびにインスタンスが作り直されて ID が変わるため、ID ではなく Name タグで指定する
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
# Prompt for SSH Host name
# ============================================
if ([string]::IsNullOrEmpty($SshHost)) {
    do {
        $answer = Read-Host "Enter SSH Host name [ec2]"
        $SshHost = if ([string]::IsNullOrWhiteSpace($answer)) { "ec2" } else { $answer.ToLower() }

        # Validate: must start with lowercase letter, contain only lowercase letters, numbers, hyphens, underscores
        if ($SshHost -notmatch '^[a-z]([a-z0-9_-]*[a-z0-9])?$') {
            Write-Host "Error: Host name must start with a lowercase letter, end with a letter or number, and contain only lowercase letters, numbers, hyphens, and underscores." -ForegroundColor Red
            $SshHost = $null
            continue
        }

        break
    } while ($true)
}

# ============================================
# Prompt for AWS Region
# ============================================
if ([string]::IsNullOrEmpty($Region)) {
    $input = Read-Host "Enter AWS Region [ap-northeast-1]"
    $Region = if ([string]::IsNullOrWhiteSpace($answer)) { "ap-northeast-1" } else { $answer }
}

# ============================================
# Set variables
# ============================================
$INSTANCE_NAME = $InstanceName
$SSH_HOST = $SshHost
$REGION = $Region
$SSH_CONFIG = "config"
$SSH_CONFIG_DIR = "$env:USERPROFILE\.ssh"
$SSH_CONFIG_PATH = "$SSH_CONFIG_DIR\$SSH_CONFIG"

# ============================================
# Create .ssh directory if needed
# ============================================
if (-not (Test-Path $SSH_CONFIG_DIR)) {
    Write-Host "Creating directory: $SSH_CONFIG_DIR" -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $SSH_CONFIG_DIR -Force | Out-Null
} else {
    Write-Host "Directory already exists: $SSH_CONFIG_DIR" -ForegroundColor Gray
}

# ============================================
# Get key pair information from EC2 instance
# ============================================
Write-Host "`nRetrieving key pair information from instance..." -ForegroundColor Cyan
$instanceIds = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Failed to look up instance: $instanceIds"
    exit 1
}

$instanceIdList = @("$instanceIds" -split '\s+' | Where-Object { $_ })
if ($instanceIdList.Count -ne 1) {
    Write-Error "Error: Expected exactly one instance tagged Name=$INSTANCE_NAME in $REGION, found $($instanceIdList.Count): $instanceIds. Check the instance_name in 'tofu output workstations'."
    exit 1
}
$INSTANCE_ID = $instanceIdList[0]

# 接続ユーザー名は OS ごとに異なるため、tofu がインスタンスに付けた LoginUser タグから取る
$USER = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].Tags[?Key=='LoginUser'].Value | [0]" --output text
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Failed to read the LoginUser tag (AWS CLI error). Check your AWS credentials (e.g. run 'aws login') and try again: $USER"
    exit 1
}
if ($USER -eq "None" -or [string]::IsNullOrEmpty($USER)) {
    Write-Error "Error: Instance $INSTANCE_ID has no LoginUser tag. Run 'tofu apply' to update the instance tags."
    exit 1
}
$KEY_NAME = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].KeyName" --output text

if ($KEY_NAME -eq "None" -or [string]::IsNullOrEmpty($KEY_NAME)) {
    Write-Error "Error: No key pair is associated with instance $INSTANCE_ID"
    exit 1
}

Write-Host "Key name: $KEY_NAME" -ForegroundColor Green

# ============================================
# Get Key Pair ID from Key Name
# ============================================
$KEY_ID = & "C:\Program Files\Amazon\AWSCLIV2\aws.exe" ec2 describe-key-pairs --key-names $KEY_NAME --region $REGION --query "KeyPairs[0].KeyPairId" --output text

Write-Host "Key pair ID: $KEY_ID" -ForegroundColor Green

$SECRET_KEY = "ec2_secret_key_$SSH_HOST.pem"
$SECRET_KEY_PATH = "$SSH_CONFIG_DIR\$SECRET_KEY"

# ============================================
# Retrieve private key from Parameter Store
# ============================================
Write-Host "`nRetrieving private key from Parameter Store..." -ForegroundColor Cyan
& "C:\Program Files\Amazon\AWSCLIV2\aws.exe" ssm get-parameter --region $REGION --name "/ec2/keypair/$KEY_ID" --with-decryption --query "Parameter.Value" --output text | Set-Content -Path $SECRET_KEY_PATH
Write-Host "Created/Updated: $SECRET_KEY_PATH" -ForegroundColor Green

# ============================================
# Set file permissions for private key
# ============================================
Write-Host "Setting file permissions..." -ForegroundColor Cyan
icacls $SECRET_KEY_PATH /inheritance:r | Out-Null
icacls $SECRET_KEY_PATH /grant "$($env:USERNAME):F" | Out-Null

# ============================================
# Copy auto-start script to .ssh directory
# ============================================
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$AUTO_START_SCRIPT = "start-ec2-and-wait.ps1"
$AUTO_START_SCRIPT_PATH = "$SSH_CONFIG_DIR\$AUTO_START_SCRIPT"

Write-Host "Copying auto-start script..." -ForegroundColor Cyan
Copy-Item -Path "$SCRIPT_DIR\$AUTO_START_SCRIPT" -Destination $AUTO_START_SCRIPT_PATH -Force
Write-Host "Created: $AUTO_START_SCRIPT_PATH" -ForegroundColor Green

# ============================================
# Convert path to Unix-style for SSH config
# ============================================
$SECRET_KEY_PATH_UNIX = $SECRET_KEY_PATH -replace '\\', '/'
$AUTO_START_SCRIPT_PATH_UNIX = $AUTO_START_SCRIPT_PATH -replace '\\', '/'

# ============================================
# Add configuration to SSH config file
# ============================================
Write-Host "`nUpdating SSH config file..." -ForegroundColor Cyan

# Remove existing host entry if exists
if (Test-Path $SSH_CONFIG_PATH) {
    $configContent = [System.IO.File]::ReadAllText($SSH_CONFIG_PATH)
    # Normalize line endings to LF
    $configContent = $configContent -replace "`r`n", "`n"

    # Remove existing entry for the same host (including comment line above it)
    $pattern = "(?m)^# Remote development EC2.*`n^Host $SSH_HOST`n(?:^   .+`n)*"
    if ($configContent -match $pattern) {
        Write-Host "Removing existing configuration for '$SSH_HOST'..." -ForegroundColor Yellow
        $configContent = $configContent -replace $pattern, ""
        # Remove trailing empty lines
        $configContent = $configContent.TrimEnd("`n") + "`n"
    }
} else {
    $configContent = ""
}

$sshConfigEntry = @"
# Remote development EC2 (Auto-start enabled)
Host $SSH_HOST
   HostName $INSTANCE_NAME
   User $USER
   IdentityFile $SECRET_KEY_PATH_UNIX
   IdentitiesOnly yes
   StrictHostKeyChecking no
   UserKnownHostsFile /dev/null
   ServerAliveInterval 60
   ProxyCommand powershell -ExecutionPolicy Bypass -File "$AUTO_START_SCRIPT_PATH_UNIX" %h $REGION %p
"@

# Append new entry
$newContent = $configContent + $sshConfigEntry + "`n"

# Write with LF line endings
[System.IO.File]::WriteAllText($SSH_CONFIG_PATH, $newContent, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updated: $SSH_CONFIG_PATH" -ForegroundColor Green

Write-Host "`n✓ Configuration complete!" -ForegroundColor Green
Write-Host "You can now connect to '$SSH_HOST' using VS Code Remote-SSH." -ForegroundColor Green
