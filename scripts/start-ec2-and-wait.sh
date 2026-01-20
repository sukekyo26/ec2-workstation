#!/bin/bash
# ============================================================
# EC2 Auto-Start and Wait Script
# EC2インスタンスの状態を確認し、停止中なら起動して待機
# VS Code Remote-SSHのProxyCommandから呼び出される
# ============================================================

set -e

# 引数チェック
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <instance-id> <region> <port-number>" >&2
    exit 1
fi

INSTANCE_ID="$1"
REGION="$2"
PORT_NUMBER="$3"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
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

    log "Error: Timeout waiting for SSM Agent to become ready after $((max_retries * retry_interval)) seconds"
    return 1
fi

# EC2インスタンスの状態を確認
if ! STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text 2>&1); then
    log "Error: Failed to get instance state: $STATE"
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

        log "Instance is now running"
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

        log "Instance is now running"
        ;;

    "pending")
        log "Instance is starting, waiting..."
        aws ec2 wait instance-running \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION"

        # SSM Agentが接続されるまで待機
        wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"

        log "Instance is now running"
        ;;

    "running")
        log "Instance is already running, checking SSM Agent..."
        # 既に起動中でもSSM Agentが接続されていない可能性があるため確認
        wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"
        ;;

    *)
        log "Error: Unexpected instance state: $STATE"
        exit 1
        ;;
esac

# SSMセッションを開始
exec aws ssm start-session \
    --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartSSHSession \
    --parameters "portNumber=$PORT_NUMBER"
