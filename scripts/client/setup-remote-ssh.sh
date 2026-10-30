#!/bin/bash
# ============================================================
# EC2 Remote Workstation - Setup Remote SSH Script
# VS Code Remote-SSH接続設定スクリプト (Linux/Mac)
# ============================================================

set -e

# 色付き出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# $1: 表示名, $2: コマンド。--version が 0 なら出力を TOOL_VERSION に入れて 0、0 以外なら出力 (空白だけの行は除く) を付けた誤りの文を出して 1
tool_version() {
    local label=$1 command=$2 rc=0
    TOOL_VERSION=$("$command" --version 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo -e "${RED}Error: ${label} failed to run: '$(command -v "$command") --version' exited with code ${rc}.${NC}"
        sed -e '/^[[:space:]]*$/d' -e 's/^/    /' <<< "$TOOL_VERSION"
        echo -e "${YELLOW}  Reinstall it, or fix PATH so that a working one comes first.${NC}"
        return 1
    fi
}

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
elif tool_version 'AWS CLI v2 (aws)' aws; then
    echo -e "  ${GREEN}${TOOL_VERSION} - OK${NC}"
else
    HAS_ERROR=true
fi

# Check Session Manager Plugin (must be in PATH for AWS CLI to use it)
if ! command -v session-manager-plugin &> /dev/null; then
    echo -e "${RED}Error: Session Manager Plugin is not installed or not in PATH.${NC}"
    echo -e "${YELLOW}  Download: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html${NC}"
    echo -e "${YELLOW}  Note: After installation, you may need to restart your shell or add the plugin to PATH.${NC}"
    HAS_ERROR=true
elif tool_version 'Session Manager Plugin (session-manager-plugin)' session-manager-plugin; then
    echo -e "  ${GREEN}Session Manager Plugin ${TOOL_VERSION} - OK${NC}"
else
    HAS_ERROR=true
fi

# Exit if any prerequisite is missing
if [ "$HAS_ERROR" = true ]; then
    echo ""
    echo -e "${RED}Please install the missing prerequisites and try again.${NC}"
    exit 1
fi

echo ""

# ============================================
# Prompt for EC2 Instance Name tag
# ============================================
# AMI 更新のたびにインスタンスが作り直されて ID が変わるため、ID ではなく Name タグで指定する
while true; do
    read -p "Enter EC2 instance Name tag (instance_name in 'tofu output workstations'): " INSTANCE_NAME

    if [ -z "$INSTANCE_NAME" ]; then
        echo -e "${RED}Error: Instance Name tag is required.${NC}"
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
if ! INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>&1); then
    echo -e "${RED}Error: Failed to look up instance: $INSTANCE_IDS${NC}" >&2
    exit 1
fi

read -ra INSTANCE_ID_LIST <<< "$INSTANCE_IDS"
if [ "${#INSTANCE_ID_LIST[@]}" -ne 1 ]; then
    echo -e "${RED}Error: Expected exactly one instance tagged Name=$INSTANCE_NAME in $REGION, found ${#INSTANCE_ID_LIST[@]}: $INSTANCE_IDS${NC}" >&2
    echo -e "${YELLOW}Check the instance_name in 'tofu output workstations'.${NC}" >&2
    exit 1
fi
INSTANCE_ID="${INSTANCE_ID_LIST[0]}"
KEY_NAME=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].KeyName" --output text)

# 接続ユーザー名は OS ごとに異なるため、tofu がインスタンスに付けた LoginUser タグから取る
SSH_USER=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --query "Reservations[0].Instances[0].Tags[?Key=='LoginUser'].Value | [0]" --output text)
if [ "$SSH_USER" = "None" ] || [ -z "$SSH_USER" ]; then
    echo -e "${RED}Error: Instance $INSTANCE_ID has no LoginUser tag. Run 'tofu apply' to update the instance tags.${NC}"
    exit 1
fi

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
# ホストごとに 1 つ: 別のホストの setup で、このホストが使うスクリプトを変えない。
# 前の版の setup が置いた共有の ~/.ssh/start-ec2-and-wait.sh は、まだ使うホストのために触らない
AUTO_START_SCRIPT_PATH="$SSH_CONFIG_DIR/ec2-workstation-proxy-$SSH_HOST.sh"

echo -e "${CYAN}Copying auto-start script...${NC}"
cp "$SCRIPT_DIR/$AUTO_START_SCRIPT" "$AUTO_START_SCRIPT_PATH"
chmod +x "$AUTO_START_SCRIPT_PATH"
echo -e "${GREEN}Created: $AUTO_START_SCRIPT_PATH${NC}"

# ============================================
# Add configuration to SSH config file
# ============================================
echo ""
echo -e "${CYAN}Updating SSH config file...${NC}"

# Remove existing host entry if exists
if [ -f "$SSH_CONFIG_PATH" ]; then
    # Check if host already exists
    if grep -q "^Host $SSH_HOST$" "$SSH_CONFIG_PATH"; then
        echo -e "${YELLOW}Removing existing configuration for '$SSH_HOST'...${NC}"
        # Create temp file without the existing entry
        # Remove comment line + Host line + all following lines starting with spaces until next non-space line or EOF
        awk -v host="$SSH_HOST" '
            BEGIN { skip = 0; prev_comment = "" }
            /^# Remote development EC2/ { prev_comment = $0; next }
            /^Host / {
                if ($2 == host) {
                    skip = 1
                    prev_comment = ""
                    next
                } else {
                    if (prev_comment != "") print prev_comment
                    prev_comment = ""
                    skip = 0
                }
            }
            /^   / { if (skip) next }
            /^[^ ]/ { if (skip && !/^Host /) skip = 0 }
            { if (!skip) { if (prev_comment != "") { print prev_comment; prev_comment = "" } print } }
        ' "$SSH_CONFIG_PATH" > "$SSH_CONFIG_PATH.tmp"
        mv "$SSH_CONFIG_PATH.tmp" "$SSH_CONFIG_PATH"
    fi
fi

# ProxyCommandを自動起動スクリプトに設定
PROXY_COMMAND="ProxyCommand \"$AUTO_START_SCRIPT_PATH\" %h $REGION %p"

SSH_CONFIG_ENTRY="# Remote development EC2 (Auto-start enabled)
Host $SSH_HOST
   HostName $INSTANCE_NAME
   User $SSH_USER
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
echo -e "${GRAY}'$SSH_HOST' runs $AUTO_START_SCRIPT_PATH. The other hosts keep their own scripts; to update one, run this setup again for that host.${NC}"
