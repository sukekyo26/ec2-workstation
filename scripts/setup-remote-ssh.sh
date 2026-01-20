#!/bin/bash
# ============================================================
# EC2 Remote Workspace - Setup Remote SSH Script
# VS Code Remote-SSH接続設定スクリプト (Linux/Mac)
# ============================================================

set -e

# 色付き出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# ============================================
# Prerequisites Check
# ============================================
echo -e "${CYAN}Checking prerequisites...${NC}"

HAS_ERROR=false

# Check Bash version
echo -e "  ${GREEN}Bash ${BASH_VERSION} - OK${NC}"

# Check AWS CLI v2
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI v2 is not installed.${NC}"
    echo -e "${YELLOW}  Download: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html${NC}"
    HAS_ERROR=true
else
    AWS_VERSION=$(aws --version 2>&1)
    echo -e "  ${GREEN}${AWS_VERSION} - OK${NC}"
fi

# Check Session Manager Plugin (must be in PATH for AWS CLI to use it)
if ! command -v session-manager-plugin &> /dev/null; then
    echo -e "${RED}Error: Session Manager Plugin is not installed or not in PATH.${NC}"
    echo -e "${YELLOW}  Download: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html${NC}"
    echo -e "${YELLOW}  Note: After installation, you may need to restart your shell or add the plugin to PATH.${NC}"
    HAS_ERROR=true
else
    SSM_VERSION=$(session-manager-plugin --version 2>&1 || echo "installed")
    echo -e "  ${GREEN}Session Manager Plugin ${SSM_VERSION} - OK${NC}"
fi

# Exit if any prerequisite is missing
if [ "$HAS_ERROR" = true ]; then
    echo ""
    echo -e "${RED}Please install the missing prerequisites and try again.${NC}"
    exit 1
fi

echo ""

# ============================================
# Prompt for EC2 Instance ID
# ============================================
while true; do
    read -p "Enter EC2 Instance ID (e.g., i-0123456789abcdef0): " INSTANCE_ID

    if [ -z "$INSTANCE_ID" ]; then
        echo -e "${RED}Error: Instance ID is required.${NC}"
        continue
    fi

    if ! [[ "$INSTANCE_ID" =~ ^i-[a-f0-9]{17}$ ]]; then
        echo -e "${RED}Error: Invalid Instance ID format. Must start with 'i-' followed by 17 hexadecimal characters.${NC}"
        continue
    fi

    break
done

# ============================================
# Prompt for SSH Host name
# ============================================
while true; do
    read -p "Enter SSH Host name [ec2]: " SSH_HOST_INPUT
    SSH_HOST=${SSH_HOST_INPUT:-ec2}
    SSH_HOST=$(echo "$SSH_HOST" | tr '[:upper:]' '[:lower:]')

    # Validate: must start with lowercase letter, contain only lowercase letters, numbers, hyphens, underscores
    if ! [[ "$SSH_HOST" =~ ^[a-z]([a-z0-9_-]*[a-z0-9])?$ ]]; then
        echo -e "${RED}Error: Host name must start with a lowercase letter, end with a letter or number, and contain only lowercase letters, numbers, hyphens, and underscores.${NC}"
        continue
    fi

    break
done

# ============================================
# Prompt for AWS Region
# ============================================
read -p "Enter AWS Region [ap-northeast-1]: " REGION_INPUT
REGION=${REGION_INPUT:-ap-northeast-1}

# ============================================
# Set variables
# ============================================
USER="ubuntu"
SSH_CONFIG_DIR="$HOME/.ssh"
SSH_CONFIG_PATH="$SSH_CONFIG_DIR/config"

# ============================================
# Create .ssh directory if needed
# ============================================
if [ ! -d "$SSH_CONFIG_DIR" ]; then
    echo -e "${CYAN}Creating directory: $SSH_CONFIG_DIR${NC}"
    mkdir -p "$SSH_CONFIG_DIR"
    chmod 700 "$SSH_CONFIG_DIR"
else
    echo -e "${GRAY}Directory already exists: $SSH_CONFIG_DIR${NC}"
fi

# ============================================
# Get key pair information from EC2 instance
# ============================================
echo ""
echo -e "${CYAN}Retrieving key pair information from instance...${NC}"
KEY_NAME=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].KeyName" --output text)

if [ "$KEY_NAME" = "None" ] || [ -z "$KEY_NAME" ]; then
    echo -e "${RED}Error: No key pair is associated with instance $INSTANCE_ID${NC}"
    exit 1
fi

echo -e "${GREEN}Key name: $KEY_NAME${NC}"

# ============================================
# Get Key Pair ID from Key Name
# ============================================
KEY_ID=$(aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" --query "KeyPairs[0].KeyPairId" --output text)

echo -e "${GREEN}Key pair ID: $KEY_ID${NC}"

SECRET_KEY="ec2_secret_key_${SSH_HOST}.pem"
SECRET_KEY_PATH="$SSH_CONFIG_DIR/$SECRET_KEY"

# ============================================
# Retrieve private key from Parameter Store
# ============================================
echo ""
echo -e "${CYAN}Retrieving private key from Parameter Store...${NC}"
aws ssm get-parameter --region "$REGION" --name "/ec2/keypair/$KEY_ID" --with-decryption --query "Parameter.Value" --output text > "$SECRET_KEY_PATH"
echo -e "${GREEN}Created/Updated: $SECRET_KEY_PATH${NC}"

# ============================================
# Set file permissions for private key
# ============================================
echo -e "${CYAN}Setting file permissions...${NC}"
chmod 600 "$SECRET_KEY_PATH"

# ============================================
# Copy auto-start script to .ssh directory
# ============================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
AUTO_START_SCRIPT="start-ec2-and-wait.sh"
AUTO_START_SCRIPT_PATH="$SSH_CONFIG_DIR/$AUTO_START_SCRIPT"

echo -e "${CYAN}Copying auto-start script...${NC}"
cp "$SCRIPT_DIR/$AUTO_START_SCRIPT" "$AUTO_START_SCRIPT_PATH"
chmod +x "$AUTO_START_SCRIPT_PATH"
echo -e "${GREEN}Created: $AUTO_START_SCRIPT_PATH${NC}"

# ============================================
# Add configuration to SSH config file
# ============================================
echo ""
echo -e "${CYAN}Updating SSH config file...${NC}"

# ProxyCommandを自動起動スクリプトに設定
PROXY_COMMAND="ProxyCommand \"$AUTO_START_SCRIPT_PATH\" %h $REGION %p"

SSH_CONFIG_ENTRY="# Remote development EC2 (Auto-start enabled)
Host $SSH_HOST
   HostName $INSTANCE_ID
   User $USER
   IdentityFile $SECRET_KEY_PATH
   IdentitiesOnly yes
   StrictHostKeyChecking no
   UserKnownHostsFile /dev/null
   ServerAliveInterval 60
   $PROXY_COMMAND
"

echo "$SSH_CONFIG_ENTRY" >> "$SSH_CONFIG_PATH"
echo -e "${GREEN}Updated: $SSH_CONFIG_PATH${NC}"

echo ""
echo -e "${GREEN}✓ Configuration complete!${NC}"
echo -e "${GREEN}You can now connect to '$SSH_HOST' using VS Code Remote-SSH.${NC}"
