#!/bin/bash
set -eux

# ============================================================
# EC2 Remote Workspace - User Data Script
# Ubuntu 24.04 LTS用初期化スクリプト
# ============================================================

# ログ設定
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=========================================="
echo "Starting EC2 Remote Workspace Setup"
echo "Date: $(date)"
echo "=========================================="

# 環境変数設定
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

# システムアップデート
echo "[1/6] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# 基本ツールインストール
echo "[2/6] Installing essential tools..."
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    nano \
    htop \
    tree \
    jq \
    unzip \
    zip \
    tar \
    gzip \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    build-essential \
    apt-transport-https \
    dnsutils \
    iputils-ping \
    net-tools

# Dockerインストール
echo "[3/6] Installing Docker..."
if ! command -v docker &> /dev/null; then
    # Docker公式インストールスクリプトを使用
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    # Dockerサービス有効化（通常は自動で有効化されるが念のため）
    systemctl enable docker
    systemctl start docker
fi

# デフォルトユーザー（ubuntu）をdockerグループに追加
usermod -aG docker ubuntu

# Docker Compose確認
echo "Docker version:"
docker --version
echo "Docker Compose version:"
docker compose version

# AWS CLI v2インストール
echo "[4/6] Installing AWS CLI v2..."
if ! command -v aws &> /dev/null; then
    cd /tmp
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi
echo "AWS CLI version:"
aws --version

# 開発用ディレクトリ作成
echo "[5/6] Setting up workspace directory..."
mkdir -p /home/ubuntu/work
chown -R ubuntu:ubuntu /home/ubuntu/work

# sudoヘルプメッセージを非表示にする
touch /home/ubuntu/.sudo_as_admin_successful
chown ubuntu:ubuntu /home/ubuntu/.sudo_as_admin_successful

# タイムゾーン設定（日本時間）
echo "[6/6] Setting timezone and swap space..."
timedatectl set-timezone Asia/Tokyo

# スワップ領域作成（メモリ不足対策）
if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 完了メッセージ
echo "=========================================="
echo "EC2 Remote Workspace Setup Complete!"
echo "Date: $(date)"
echo "=========================================="
echo ""
echo "Installed software:"
echo "  - Docker: $(docker --version)"
echo "  - AWS CLI: $(aws --version)"
echo "  - Git: $(git --version)"
echo ""
echo "You can now connect via AWS Systems Manager Session Manager."
