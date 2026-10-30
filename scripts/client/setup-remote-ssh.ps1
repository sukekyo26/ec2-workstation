param(
    [Parameter(Mandatory=$false)]
    [string]$InstanceName,

    [Parameter(Mandatory=$false)]
    [string]$SshHost,

    [Parameter(Mandatory=$false)]
    [string]$Region
)

# The host name becomes part of file names in ~/.ssh, so it is lowercased (NTFS ignores case) and kept to
# letters, digits, - and _. Returns the lowercased name, or $null when it is not valid
function ConvertTo-SshHostName {
    param([string]$Name)
    $lower = $Name.ToLowerInvariant()
    # \z, not $: in .NET, $ also matches before a final newline
    if ($lower -cmatch '^[a-z]([a-z0-9_-]*[a-z0-9])?\z') {
        return $lower
    }
    return $null
}
$hostNameRule = "Host name must start with a lowercase letter, end with a letter or number, and contain only lowercase letters, numbers, hyphens, and underscores."

# Runs <Path> --version. Returns its output on one line ('' when there is none) when it exits 0; otherwise (or when it
# does not start) prints the error with all of the output and returns $null. Only the exit code decides: 5.1 turns
# stderr lines into ErrorRecords even on success (AWS CLI v1 prints its version on stderr)
function Get-ToolVersion {
    param([string]$Label, [string]$Path)
    $failure = $null
    try {
        $output = @(& $Path --version 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    # "$_" would turn an empty stderr line into System.Management.Automation.RemoteException
                    if ($_.TargetObject -is [string]) { $_.TargetObject } else { $_.Exception.Message }
                } else {
                    "$_"
                }
            } | Where-Object { $_.Trim() })
        if ($LASTEXITCODE -ne 0) {
            $failure = "exited with code $LASTEXITCODE"
        }
    } catch {
        # Not a valid executable for this OS, blocked by policy, ...: $LASTEXITCODE still holds the previous command's code
        $output = @($_.Exception.Message -split "`r?`n" | Where-Object { $_.Trim() })
        $failure = 'could not start'
    }
    if ($failure) {
        Write-Host "Error: $Label failed to run: '$Path --version' $failure." -ForegroundColor Red
        foreach ($line in $output) {
            Write-Host "    $line" -ForegroundColor Yellow
        }
        Write-Host "  Reinstall it, or fix PATH so that a working one comes first." -ForegroundColor Yellow
        return $null
    }
    return ($output -join ' ')
}

# ============================================
# Prerequisites Check
# ============================================
Write-Host "Checking prerequisites..." -ForegroundColor Cyan

$hasError = $false

# Check PowerShell version
Write-Host "  PowerShell $($PSVersionTable.PSVersion) - OK" -ForegroundColor Green

# Check AWS CLI v2
$awsCli = (Get-Command aws -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if (-not $awsCli) {
    Write-Host "Error: AWS CLI v2 (aws) is not installed or not in PATH." -ForegroundColor Red
    Write-Host "  Download: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" -ForegroundColor Yellow
    Write-Host "  Note: After installation, restart VS Code or PowerShell so that PATH is reloaded." -ForegroundColor Yellow
    $hasError = $true
} else {
    $awsVersion = Get-ToolVersion -Label 'AWS CLI v2 (aws)' -Path $awsCli
    if ($null -eq $awsVersion) {
        $hasError = $true
    } else {
        Write-Host "  $awsVersion - OK" -ForegroundColor Green
    }
}

# Check Session Manager Plugin (must be in PATH for AWS CLI to use it)
$ssmPlugin = (Get-Command session-manager-plugin -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Path
if (-not $ssmPlugin) {
    Write-Host "Error: Session Manager Plugin is not installed or not in PATH." -ForegroundColor Red
    Write-Host "  Download: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" -ForegroundColor Yellow
    Write-Host "  Note: After installation, you may need to restart PowerShell or add the plugin to PATH." -ForegroundColor Yellow
    $hasError = $true
} else {
    $ssmVersion = Get-ToolVersion -Label 'Session Manager Plugin (session-manager-plugin)' -Path $ssmPlugin
    if ($null -eq $ssmVersion) {
        $hasError = $true
    } else {
        Write-Host "  Session Manager Plugin $ssmVersion - OK" -ForegroundColor Green
    }
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
        $SshHost = ConvertTo-SshHostName $(if ([string]::IsNullOrWhiteSpace($answer)) { "ec2" } else { $answer })
        if ($null -eq $SshHost) {
            Write-Host "Error: $hostNameRule" -ForegroundColor Red
            continue
        }

        break
    } while ($true)
} else {
    # -SshHost cannot be asked again, so a bad one stops here
    $name = ConvertTo-SshHostName $SshHost
    if ($null -eq $name) {
        Write-Error "Error: '$SshHost' is not a valid host name. $hostNameRule"
        exit 1
    }
    $SshHost = $name
}

# ============================================
# Prompt for AWS Region
# ============================================
if ([string]::IsNullOrEmpty($Region)) {
    $answer = Read-Host "Enter AWS Region [ap-northeast-1]"
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
$instanceIds = & $awsCli ec2 describe-instances --region $REGION --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query "Reservations[].Instances[].InstanceId" --output text
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
$SSH_USER = & $awsCli ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].Tags[?Key=='LoginUser'].Value | [0]" --output text
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error: Failed to read the LoginUser tag (AWS CLI error). Check your AWS credentials (e.g. run 'aws login') and try again: $SSH_USER"
    exit 1
}
if ($SSH_USER -eq "None" -or [string]::IsNullOrEmpty($SSH_USER)) {
    Write-Error "Error: Instance $INSTANCE_ID has no LoginUser tag. Run 'tofu apply' to update the instance tags."
    exit 1
}
$KEY_NAME = & $awsCli ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION --query "Reservations[0].Instances[0].KeyName" --output text

if ($KEY_NAME -eq "None" -or [string]::IsNullOrEmpty($KEY_NAME)) {
    Write-Error "Error: No key pair is associated with instance $INSTANCE_ID"
    exit 1
}

Write-Host "Key name: $KEY_NAME" -ForegroundColor Green

# ============================================
# Get Key Pair ID from Key Name
# ============================================
$KEY_ID = & $awsCli ec2 describe-key-pairs --key-names $KEY_NAME --region $REGION --query "KeyPairs[0].KeyPairId" --output text

Write-Host "Key pair ID: $KEY_ID" -ForegroundColor Green

$SECRET_KEY = "ec2_secret_key_$SSH_HOST.pem"
$SECRET_KEY_PATH = "$SSH_CONFIG_DIR\$SECRET_KEY"

# ============================================
# Retrieve private key from Parameter Store
# ============================================
Write-Host "`nRetrieving private key from Parameter Store..." -ForegroundColor Cyan
& $awsCli ssm get-parameter --region $REGION --name "/ec2/keypair/$KEY_ID" --with-decryption --query "Parameter.Value" --output text | Set-Content -Path $SECRET_KEY_PATH
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
# One script per host: a setup for another host must not change the script this host runs.
# An older setup's shared ~/.ssh/start-ec2-and-wait.ps1 is left as it is for the hosts that still use it
$AUTO_START_SCRIPT_PATH = "$SSH_CONFIG_DIR\ec2-workstation-proxy-$SSH_HOST.ps1"

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
   User $SSH_USER
   IdentityFile $SECRET_KEY_PATH_UNIX
   IdentitiesOnly yes
   StrictHostKeyChecking no
   UserKnownHostsFile /dev/null
   ServerAliveInterval 60
   ProxyCommand powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$AUTO_START_SCRIPT_PATH_UNIX" %h $REGION %p
"@

# Append new entry
$newContent = $configContent + $sshConfigEntry + "`n"

# Write with LF line endings
[System.IO.File]::WriteAllText($SSH_CONFIG_PATH, $newContent, [System.Text.UTF8Encoding]::new($false))
Write-Host "Updated: $SSH_CONFIG_PATH" -ForegroundColor Green

Write-Host "`n✓ Configuration complete!" -ForegroundColor Green
Write-Host "You can now connect to '$SSH_HOST' using VS Code Remote-SSH." -ForegroundColor Green
Write-Host "'$SSH_HOST' runs $AUTO_START_SCRIPT_PATH. The other hosts keep their own scripts; to update one, run this setup again for that host." -ForegroundColor Gray
