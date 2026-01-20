#!/bin/bash
# ============================================================
# EC2 Auto-Start Script
# EC2インスタンスを起動してSSM Agent接続完了まで待機
# VS Code Remote-SSH接続前に手動で実行します
# ============================================================

set -e

# 色付き出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 引数を変数に代入
INSTANCE_ID="$1"
REGION="$2"

# ============================================
# Prompt for EC2 Instance ID
# ============================================
if [ -z "$INSTANCE_ID" ]; then
    while true; do
        read -rp "Enter EC2 Instance ID (e.g., i-0123456789abcdef0): " INSTANCE_ID

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
fi

# ============================================
# Prompt for AWS Region
# ============================================
if [ -z "$REGION" ]; then
    read -rp "Enter AWS Region [ap-northeast-1]: " REGION_INPUT
    REGION=${REGION_INPUT:-ap-northeast-1}
fi

log() {
    echo -e "${CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# SSM Agentの接続状態を確認して待機
wait_ssm_agent_ready() {
    local instance_id="$1"
    local region="$2"
    local max_retries=60
    local retry_interval=5

    log "Waiting for SSM Agent to be ready..."

    for ((i=1; i<=max_retries; i++)); do
        ping_status=$(aws ssm describe-instance-information \
            --region "$region" \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --query "InstanceInformationList[0].PingStatus" \
            --output text 2>/dev/null || echo "None")

        if [ "$ping_status" = "Online" ]; then
            log "SSM Agent is online"
            return 0
        fi

        log "SSM Agent not ready yet (attempt $i/$max_retries, status: $ping_status)"
        sleep "$retry_interval"
    done

    echo -e "${RED}Error: Timeout waiting for SSM Agent to become ready after $((max_retries * retry_interval)) seconds${NC}" >&2
    return 1
fi

log "Checking EC2 instance state..."

# EC2インスタンスの状態を確認
if ! STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text 2>&1); then
    echo -e "${RED}Error: Failed to get instance state: $STATE${NC}" >&2
    exit 1
fi

log "Instance $INSTANCE_ID state: $STATE"

case "$STATE" in
    "stopped")
        log "Starting instance $INSTANCE_ID..."
        aws ec2 start-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION" > /dev/null 2>&1

        log "Waiting for instance to be running..."
        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION"

        # SSM Agentが接続されるまで待機
        wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"

        log "Instance is now running and ready for SSH connection"
        ;;

    "stopping")
        log "Instance is stopping, waiting for it to stop..."
        aws ec2 wait instance-stopped \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION"

        log "Starting instance $INSTANCE_ID..."
        aws ec2 start-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION" > /dev/null 2>&1

        log "Waiting for instance to be running..."
        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION"

        # SSM Agentが接続されるまで待機
        wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"

        log "Instance is now running and ready for SSH connection"
        ;;

    "pending")
        log "Instance is starting, waiting..."
        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION"

        # SSM Agentが接続されるまで待機
        wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"

        log "Instance is now running and ready for SSH connection"
        ;;

    "running")
        log "Instance is already running, checking SSM Agent..."
        # 既に起動中でもSSM Agentが接続されていない可能性があるため確認
        wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"
        log "Instance is ready for SSH connection"
        ;;

    *)
        echo -e "${RED}Error: Unexpected instance state: $STATE${NC}" >&2
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}✓ EC2 instance is ready!${NC}"
echo -e "${GREEN}You can now connect using VS Code Remote-SSH.${NC}"
