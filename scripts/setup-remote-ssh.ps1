param(
    [Parameter(Mandatory=$false)]
    [string]$InstanceId,

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
# Prompt for EC2 Instance ID
# ============================================
if ([string]::IsNullOrEmpty($InstanceId)) {
    do {
        $InstanceId = Read-Host "Enter EC2 Instance ID (e.g., i-0123456789abcdef0)"

        if ([string]::IsNullOrEmpty($InstanceId)) {
            Write-Host "Error: Instance ID is required." -ForegroundColor Red
            continue
        }

        if ($InstanceId -notmatch '^i-[a-f0-9]{17}$') {
            Write-Host "Error: Invalid Instance ID format. Must start with 'i-' followed by 17 hexadecimal characters." -ForegroundColor Red
            $InstanceId = $null
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
        $input = Read-Host "Enter SSH Host name [ec2]"
        $SshHost = if ([string]::IsNullOrWhiteSpace($input)) { "ec2" } else { $input.ToLower() }

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
    $Region = if ([string]::IsNullOrWhiteSpace($input)) { "ap-northeast-1" } else { $input }
}

# ============================================
# Set variables
# ============================================
$INSTANCE_ID = $InstanceId
$SSH_HOST = $SshHost
$REGION = $Region
$USER = "ubuntu"
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
$sshConfigContent = @"
# Remote development EC2 (Auto-start enabled)
Host $SSH_HOST
   HostName $INSTANCE_ID
   User $USER
   IdentityFile $SECRET_KEY_PATH_UNIX
   IdentitiesOnly yes
   ServerAliveInterval 60
   ProxyCommand powershell -ExecutionPolicy Bypass -File "$AUTO_START_SCRIPT_PATH_UNIX" %h $REGION %p
"@

Add-Content -Path $SSH_CONFIG_PATH -Value $sshConfigContent
Write-Host "Updated: $SSH_CONFIG_PATH" -ForegroundColor Green

Write-Host "`n✓ Configuration complete!" -ForegroundColor Green
Write-Host "You can now connect to '$SSH_HOST' using VS Code Remote-SSH." -ForegroundColor Green
