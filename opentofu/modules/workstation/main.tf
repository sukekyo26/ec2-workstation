# 個人用ワークステーションの EC2 インスタンス
# - OS は workstation-config.json の os で選び、AMI はデプロイのたびに最新へ追従する
# - ルートボリューム暗号化 / IMDSv2 強制
# - 作業データはデータボリューム (storage.tf) に置き、インスタンスの作り直しでも残す

locals {
  resource_prefix = "${var.project_name}-${var.environment}-${var.username}"

  # 最新 AMI は各ディストリビューションが公開する SSM パブリックパラメータから引く。
  # キーと workstation-config.schema.json の definitions.os の enum が一致することは CI が確かめる
  os_image = jsondecode(file("${path.module}/os-images.json"))[var.os]
}

# ============================================================
# EC2 Instance
# ============================================================

data "aws_ssm_parameter" "ami" {
  name = local.os_image.ami_parameter
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = true
  # cloud-init は同じインスタンスでは user-data を走らせ直さないため、変わったら作り直して反映する
  user_data_replace_on_change = true
  # EC2 の user-data は base64 にする前で 16KB まで。cloud-init は gzip を見分けて展開するので、gzip して渡す
  # LIMIT: 上限は base64 前で 16KB。余裕を見て base64 後の長さで 16KB 未満を CI で見る (今は約 8.8KB)。超えたら S3 から取る形に作り直す
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    data_volume_id = aws_ebs_volume.data.id
    username       = var.username
    login_user     = local.os_image.login_user
  }))

  # IMDSv2 強制 (SSRF 対策)
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = var.root_volume_type
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name     = "${local.resource_prefix}-instance"
    Owner    = var.username
    Schedule = "office-hours"
    # scripts/setup-remote-ssh が SSH の接続ユーザー名として読む
    LoginUser = local.os_image.login_user
  }
}
