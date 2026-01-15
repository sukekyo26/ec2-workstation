#!/bin/bash
set -e

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
echo "[1/8] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# 基本ツールインストール
echo "[2/8] Installing essential tools..."
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
    apt-transport-https

# SSM Agentインストール（Ubuntu用）
echo "[3/8] Installing SSM Agent..."
if ! command -v amazon-ssm-agent &> /dev/null; then
    mkdir -p /tmp/ssm
    cd /tmp/ssm
    wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
    dpkg -i amazon-ssm-agent.deb
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    cd /
    rm -rf /tmp/ssm
fi

# SSM Agentステータス確認
echo "SSM Agent Status:"
systemctl status amazon-ssm-agent --no-pager || true

# Dockerインストール
echo "[4/8] Installing Docker..."
if ! command -v docker &> /dev/null; then
    # Docker公式GPGキー追加
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Dockerリポジトリ追加
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Dockerサービス有効化
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
echo "[5/8] Installing AWS CLI v2..."
if ! command -v aws &> /dev/null; then
    cd /tmp
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi
echo "AWS CLI version:"
aws --version

# Node.js (via nvm) インストール
echo "[6/8] Installing Node.js via nvm..."
NVM_VERSION="v0.40.1"
NODE_VERSION="22"

# ubuntuユーザーとしてnvmをインストール
sudo -u ubuntu bash << 'EOFNVM'
export HOME=/home/ubuntu
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 22
nvm use 22
nvm alias default 22
EOFNVM

# Python環境セットアップ
echo "[7/8] Setting up Python environment..."
apt-get install -y python3 python3-pip python3-venv

# pipのアップグレード
python3 -m pip install --upgrade pip --break-system-packages || true

# VS Code Server用の設定ディレクトリ作成
echo "[8/8] Setting up VS Code Server directories..."
mkdir -p /home/ubuntu/.vscode-server
chown -R ubuntu:ubuntu /home/ubuntu/.vscode-server

# 開発用ディレクトリ作成
mkdir -p /home/ubuntu/workspace
chown -R ubuntu:ubuntu /home/ubuntu/workspace

# タイムゾーン設定（日本時間）
timedatectl set-timezone Asia/Tokyo

# スワップ領域作成（メモリ不足対策）
echo "Creating swap space..."
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
echo "  - Python: $(python3 --version)"
echo "  - Git: $(git --version)"
echo ""
echo "SSM Agent Status:"
systemctl status amazon-ssm-agent --no-pager || true
echo ""
echo "You can now connect via AWS Systems Manager Session Manager."
