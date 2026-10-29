# ============================================================
# データボリューム
# インスタンス (= ルートボリューム) は AMI 更新のたびに作り直されるため、
# 作業データはインスタンスと独立したこのボリュームに置く。
# ============================================================

resource "aws_ebs_volume" "data" {
  availability_zone = var.availability_zone
  size              = var.data_volume_size
  type              = var.data_volume_type
  encrypted         = true
  # ユーザー削除・tofu destroy でボリュームが消えるときもスナップショットを残す
  final_snapshot = true

  tags = {
    Name  = "${local.resource_prefix}-data"
    Owner = var.username
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
  # 稼働中のデタッチでファイルシステムを壊さないよう、先にインスタンスを停止する
  stop_instance_before_detaching = true
}
