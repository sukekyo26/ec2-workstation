#!/bin/bash
set -eux

# ============================================================
# EC2 Remote Workstation - User Data Script
# Ubuntu 24.04 LTS用初期化スクリプト
# ============================================================

# ログ設定
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2> /dev/console) 2>&1

echo "=========================================="
echo "Starting EC2 Remote Workstation Setup"
echo "Date: $(date)"
echo "=========================================="

# 環境変数設定
export DEBIAN_FRONTEND=noninteractive
export HOME=/root

# システムアップデート
echo "[1/7] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# 基本ツールインストール
echo "[2/7] Installing essential tools..."
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    nano \
    htop \
    tree \
    jq \
    bc \
    unzip \
    zip \
    tar \
    gzip \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    uuid-runtime \
    build-essential \
    apt-transport-https \
    dnsutils \
    iputils-ping \
    net-tools

# データボリュームのマウント
# AMI 更新でルートボリュームが作り直されても残すデータ (~/work・Docker・~/.gitconfig) を置く。
# Docker インストールより前に bind mount しておき、最初からデータボリュームに書かせる。
echo "[3/7] Mounting data volume..."
# shellcheck disable=SC2154 # tofu の templatefile で埋め込まれる
DATA_VOLUME_ID="${data_volume_id}"
DATA_MOUNT=/data
DEFAULT_USER=$(id -nu 1000)
DEFAULT_HOME=$(getent passwd "$DEFAULT_USER" | cut -d: -f6)

# アタッチはインスタンス起動後に行われるため、デバイスが現れるまで待つ。
# Nitro は NVMe シリアル (ボリューム ID からハイフンを除いたもの)、Xen は /dev/xvdf で見える。
DATA_DEVICE=""
for _ in $(seq 1 120); do
    for candidate in "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$(echo "$DATA_VOLUME_ID" | tr -d -)" /dev/xvdf; do
        if [ -b "$candidate" ]; then
            DATA_DEVICE=$(readlink -f "$candidate")
            break 2
        fi
    done
    sleep 5
done
if [ -z "$DATA_DEVICE" ]; then
    echo "ERROR: data volume $DATA_VOLUME_ID was not attached within 10 minutes. Check the aws_volume_attachment in tofu apply output." >&2
    exit 1
fi

# ファイルシステムが無いとき (初回) だけフォーマットする。既存データは上書きしない。
if [ -z "$(blkid -o value -s TYPE "$DATA_DEVICE")" ]; then
    mkfs.ext4 -q "$DATA_DEVICE"
fi
DATA_UUID=$(blkid -o value -s UUID "$DATA_DEVICE")

mkdir -p "$DATA_MOUNT"
if ! grep -q "$DATA_UUID" /etc/fstab; then
    echo "UUID=$DATA_UUID $DATA_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi
mountpoint -q "$DATA_MOUNT" || mount "$DATA_MOUNT"
# ボリュームを拡張した場合に追従する (サイズが同じなら何もしない)
resize2fs "$DATA_DEVICE"

for dir in work docker containerd; do
    if [ ! -d "$DATA_MOUNT/$dir" ]; then
        mkdir -p "$DATA_MOUNT/$dir"
        if [ "$dir" = work ]; then
            chown "$DEFAULT_USER:$DEFAULT_USER" "$DATA_MOUNT/$dir"
        fi
    fi
done

# containerd image store (Docker 29 以降の既定) は /var/lib/docker とは別に
# /var/lib/containerd へイメージを置くため、両方をデータボリュームに向ける
for target in "$DEFAULT_HOME/work:work" /var/lib/docker:docker /var/lib/containerd:containerd; do
    mount_point=$(echo "$target" | cut -d: -f1)
    source_dir="$DATA_MOUNT/$(echo "$target" | cut -d: -f2)"
    mkdir -p "$mount_point"
    if ! grep -q " $mount_point none bind" /etc/fstab; then
        echo "$source_dir $mount_point none bind,nofail,x-systemd.requires-mounts-for=$DATA_MOUNT 0 0" >> /etc/fstab
    fi
    mountpoint -q "$mount_point" || mount "$mount_point"
done
chown "$DEFAULT_USER:$DEFAULT_USER" "$DEFAULT_HOME/work"

# 再起動時にマウント完了前に Docker が起動して空のディレクトリへ書き込まないようにする
for unit in docker containerd; do
    mkdir -p "/etc/systemd/system/$unit.service.d"
    cat > "/etc/systemd/system/$unit.service.d/data-volume.conf" << 'UNIT'
[Unit]
RequiresMountsFor=/var/lib/docker /var/lib/containerd
UNIT
done
systemctl daemon-reload

# git の設定 (git config --global) はデータボリューム上の実体を指すシンボリックリンクにする
if [ ! -f "$DATA_MOUNT/gitconfig" ]; then
    touch "$DATA_MOUNT/gitconfig"
    chown "$DEFAULT_USER:$DEFAULT_USER" "$DATA_MOUNT/gitconfig"
fi
ln -sfn "$DATA_MOUNT/gitconfig" "$DEFAULT_HOME/.gitconfig"
chown -h "$DEFAULT_USER:$DEFAULT_USER" "$DEFAULT_HOME/.gitconfig"

# Dockerインストール
echo "[4/7] Installing Docker..."
if ! command -v docker &> /dev/null; then
    # Docker公式インストールスクリプトを使用
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    # Dockerサービス有効化（通常は自動で有効化されるが念のため）
    systemctl enable docker
    systemctl start docker
fi

# デフォルトユーザーをdockerグループに追加
usermod -aG docker "$DEFAULT_USER"

# Docker Compose確認
echo "Docker version:"
docker --version
echo "Docker Compose version:"
docker compose version

# AWS CLI v2インストール
echo "[5/7] Installing AWS CLI v2..."
if ! command -v aws &> /dev/null; then
    cd /tmp
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    ./aws/install
    rm -rf aws awscliv2.zip
fi
echo "AWS CLI version:"
aws --version

# sudoヘルプメッセージを非表示にする
echo "[6/7] Configuring user environment..."
touch "$DEFAULT_HOME/.sudo_as_admin_successful"
chown "$DEFAULT_USER:$DEFAULT_USER" "$DEFAULT_HOME/.sudo_as_admin_successful"

# タイムゾーン設定（日本時間）
echo "[7/7] Setting timezone and swap space..."
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
echo "EC2 Remote Workstation Setup Complete!"
echo "Date: $(date)"
echo "=========================================="
echo ""
echo "Installed software:"
echo "  - Docker: $(docker --version)"
echo "  - AWS CLI: $(aws --version)"
echo "  - Git: $(git --version)"
echo ""
echo "You can now connect via AWS Systems Manager Session Manager."
