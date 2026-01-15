#!/bin/bash
# ============================================================
# EC2 Remote Workspace - 接続スクリプト
# SessionManager経由でEC2インスタンスに接続
# ============================================================

set -e

# 色付き出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ヘルプメッセージ
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "EC2 Remote Workspaceに接続するスクリプト"
    echo ""
    echo "Options:"
    echo "  -u, --username USERNAME   接続するワークスペースのユーザー名"
    echo "  -i, --instance-id ID      直接インスタンスIDを指定"
    echo "  -p, --profile PROFILE     使用するAWSプロファイル"
    echo "  -r, --region REGION       AWSリージョン (デフォルト: ap-northeast-1)"
    echo "  -l, --list                利用可能なワークスペースを一覧表示"
    echo "  -s, --start               接続前にインスタンスを起動"
    echo "  -h, --help                このヘルプを表示"
    echo ""
    echo "Examples:"
    echo "  $0 -u developer1                    # developer1のワークスペースに接続"
    echo "  $0 -i i-1234567890abcdef0          # インスタンスIDを直接指定"
    echo "  $0 -u developer1 -s                # インスタンスを起動して接続"
    echo "  $0 -l                              # 利用可能なワークスペースを一覧表示"
}

# デフォルト値
REGION="ap-northeast-1"
AWS_PROFILE=""
USERNAME=""
INSTANCE_ID=""
START_INSTANCE=false
LIST_MODE=false

# 引数パース
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -i|--instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -p|--profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -l|--list)
            LIST_MODE=true
            shift
            ;;
        -s|--start)
            START_INSTANCE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

# AWSコマンド構築
AWS_CMD="aws"
if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD="$AWS_CMD --profile $AWS_PROFILE"
fi
AWS_CMD="$AWS_CMD --region $REGION"

# AWS CLIの確認
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI がインストールされていません${NC}"
    echo "インストール方法: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

# Session Manager プラグインの確認
if ! command -v session-manager-plugin &> /dev/null; then
    echo -e "${RED}Error: Session Manager プラグインがインストールされていません${NC}"
    echo "インストール方法: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    exit 1
fi

# ワークスペース一覧表示
list_workspaces() {
    echo -e "${BLUE}利用可能なワークスペース一覧:${NC}"
    echo ""

    $AWS_CMD ec2 describe-instances \
        --filters "Name=tag:Project,Values=ec2-remote-workspace" \
                  "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].{
            InstanceId: InstanceId,
            Owner: Tags[?Key==`Owner`].Value | [0],
            State: State.Name,
            Type: InstanceType,
            LaunchTime: LaunchTime
        }' \
        --output table
}

# インスタンスIDを取得
get_instance_id() {
    local username=$1

    $AWS_CMD ec2 describe-instances \
        --filters "Name=tag:Owner,Values=$username" \
                  "Name=tag:Project,Values=ec2-remote-workspace" \
                  "Name=instance-state-name,Values=running,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text
}

# インスタンスの状態を取得
get_instance_state() {
    local instance_id=$1

    $AWS_CMD ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[].Instances[].State.Name' \
        --output text
}

# インスタンスを起動
start_instance() {
    local instance_id=$1

    echo -e "${YELLOW}インスタンスを起動中...${NC}"
    $AWS_CMD ec2 start-instances --instance-ids "$instance_id" > /dev/null

    echo -e "${YELLOW}インスタンスの起動を待機中...${NC}"
    $AWS_CMD ec2 wait instance-running --instance-ids "$instance_id"

    echo -e "${YELLOW}SSM Agentの準備を待機中... (最大60秒)${NC}"
    sleep 30  # SSM Agentの起動を待つ

    echo -e "${GREEN}インスタンスが起動しました${NC}"
}

# メイン処理
main() {
    # 一覧表示モード
    if [ "$LIST_MODE" = true ]; then
        list_workspaces
        exit 0
    fi

    # インスタンスIDの取得
    if [ -z "$INSTANCE_ID" ]; then
        if [ -z "$USERNAME" ]; then
            echo -e "${RED}Error: ユーザー名(-u)またはインスタンスID(-i)を指定してください${NC}"
            show_help
            exit 1
        fi

        echo -e "${BLUE}ユーザー '$USERNAME' のワークスペースを検索中...${NC}"
        INSTANCE_ID=$(get_instance_id "$USERNAME")

        if [ -z "$INSTANCE_ID" ]; then
            echo -e "${RED}Error: ユーザー '$USERNAME' のワークスペースが見つかりません${NC}"
            echo "利用可能なワークスペースを確認してください: $0 -l"
            exit 1
        fi

        echo -e "${GREEN}インスタンスID: $INSTANCE_ID${NC}"
    fi

    # インスタンスの状態確認
    STATE=$(get_instance_state "$INSTANCE_ID")
    echo -e "${BLUE}インスタンスの状態: $STATE${NC}"

    # インスタンスの起動（必要な場合）
    if [ "$STATE" = "stopped" ]; then
        if [ "$START_INSTANCE" = true ]; then
            start_instance "$INSTANCE_ID"
        else
            echo -e "${YELLOW}インスタンスは停止中です。起動するには -s オプションを使用してください${NC}"
            exit 1
        fi
    elif [ "$STATE" != "running" ]; then
        echo -e "${RED}Error: インスタンスの状態が '$STATE' です。running または stopped の状態でのみ接続できます${NC}"
        exit 1
    fi

    # SSM Session開始
    echo -e "${GREEN}SessionManagerで接続中...${NC}"
    echo "---"

    $AWS_CMD ssm start-session --target "$INSTANCE_ID"
}

main
