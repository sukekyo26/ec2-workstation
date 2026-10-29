#!/bin/bash
# ============================================================
# EC2 Auto-Start and Wait Script
# EC2インスタンスの状態を確認し、停止中なら起動して待機
# VS Code Remote-SSHのProxyCommandから呼び出される
# ============================================================

set -e

# 引数チェック
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <instance-name-tag> <region> <port-number>" >&2
    exit 1
fi

INSTANCE_NAME="$1"
REGION="$2"
PORT_NUMBER="$3"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# AWS認証エラーメッセージを表示
show_aws_authentication_error() {
    echo "" >&2
    echo "============================================" >&2
    echo "ERROR: AWS authentication failed" >&2
    echo "============================================" >&2
    echo "" >&2
    echo "Your AWS credentials may be expired or not configured." >&2
    echo "" >&2
    echo "Please run the following command to authenticate:" >&2
    echo "" >&2
    echo "    aws login" >&2
    echo "" >&2
    echo "Then try connecting again." >&2
    echo "============================================" >&2
    echo "" >&2
}

# SSM Agentの接続状態を確認して待機する。問い合わせの一時的な失敗 (スロットリング・ネットワークの断) は待って問い合わせ直し、
# 続けて max_failures 回失敗したら、認証の切れなど待っても直らないものとして止まる (成功を 1 回挟めば数え直す)
wait_ssm_agent_ready() {
    local instance_id="$1"
    local region="$2"
    local max_retries=60
    local retry_interval=5
    local max_failures=3
    local failures=0
    local i ping_status

    # EC2WS_SSM_POLL_INTERVAL はテストのための環境変数 (問い合わせの間隔を縮める)。1〜9999 の整数のときだけ使い、
    # ほかの値は既定のまま (ProxyCommand が誤った値を読んで止まらないように)
    if [[ "${EC2WS_SSM_POLL_INTERVAL:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
        retry_interval=$EC2WS_SSM_POLL_INTERVAL
    fi

    log "Waiting for SSM Agent to be ready..."

    for ((i = 1; i <= max_retries; i++)); do
        if ping_status=$(aws ssm describe-instance-information \
            --region "$region" \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --query "InstanceInformationList[0].PingStatus" \
            --output text); then
            failures=0
            if [ "$ping_status" = "Online" ]; then
                log "SSM Agent is online"
                return 0
            fi
            log "SSM Agent not ready yet (attempt $i/$max_retries, status: $ping_status)"
        else
            failures=$((failures + 1))
            if [ "$failures" -ge "$max_failures" ]; then
                show_aws_authentication_error
                log "Error: Failed to check the SSM Agent of $instance_id $max_failures times in a row (the aws error is above)"
                return 1
            fi
            log "Failed to check the SSM Agent (attempt $i/$max_retries, failure $failures/$max_failures), retrying"
        fi
        sleep "$retry_interval"
    done

    log "Error: Timeout waiting for SSM Agent to become ready after $((max_retries * retry_interval)) seconds"
    return 1
}

start_instance() {
    log "Starting instance $INSTANCE_ID..."
    # stdout には起動の結果の JSON が出るので捨てる。stderr (失敗の理由) はそのまま出す
    if ! aws ec2 start-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" > /dev/null; then
        log "Error: Failed to start instance $INSTANCE_ID (the aws error is above)"
        exit 1
    fi
}

# wait_instance_state <running | stopped>
wait_instance_state() {
    if ! aws ec2 wait "instance-$1" \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION"; then
        log "Error: Failed while waiting for instance $INSTANCE_ID to be $1 (the aws error is above)"
        exit 1
    fi
}

# Name タグからインスタンス ID を引く
# AMI 更新のたびにインスタンスが作り直されて ID が変わるため、SSH config には Name タグを書いている
if ! INSTANCE_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$INSTANCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text); then
    show_aws_authentication_error
    log "Error: Failed to look up instance (the aws error is above)"
    exit 1
fi

read -ra INSTANCE_ID_LIST <<< "$INSTANCE_IDS"
if [ "${#INSTANCE_ID_LIST[@]}" -ne 1 ]; then
    log "Error: Expected exactly one instance tagged Name=$INSTANCE_NAME in $REGION, found ${#INSTANCE_ID_LIST[@]}: $INSTANCE_IDS"
    log "Check the instance_name in 'tofu output workstations' and re-run setup-remote-ssh if it changed."
    exit 1
fi
INSTANCE_ID="${INSTANCE_ID_LIST[0]}"

# EC2インスタンスの状態を確認
if ! STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text); then
    # 認証エラーの可能性があるためメッセージを表示
    show_aws_authentication_error
    log "Error: Failed to get instance state (the aws error is above)"
    exit 1
fi

log "Instance $INSTANCE_ID state: $STATE"

case "$STATE" in
    "stopped")
        start_instance
        log "Waiting for instance to be running..."
        wait_instance_state running
        ;;

    "stopping")
        log "Instance is stopping, waiting for it to stop..."
        wait_instance_state stopped
        start_instance
        log "Waiting for instance to be running..."
        wait_instance_state running
        ;;

    "pending")
        log "Instance is starting, waiting..."
        wait_instance_state running
        ;;

    "running")
        log "Instance is already running, checking SSM Agent..."
        ;;

    *)
        log "Error: Unexpected instance state: $STATE"
        exit 1
        ;;
esac

# 起動した後も、既に起動中でも、SSM Agent が接続されていない可能性があるため確認
wait_ssm_agent_ready "$INSTANCE_ID" "$REGION"

# SSMセッションを開始
exec aws ssm start-session \
    --region "$REGION" \
    --target "$INSTANCE_ID" \
    --document-name AWS-StartSSHSession \
    --parameters "portNumber=$PORT_NUMBER"
