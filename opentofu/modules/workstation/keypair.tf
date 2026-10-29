# SSH キーペア
# 秘密鍵を SSM Parameter Store の /ec2/keypair/{key_pair_id} に保存する。
# このパスは scripts/client/setup-remote-ssh.sh が秘密鍵取得に使う契約
# (AWS マネージドキーペアと同じ命名規則)。

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = "${local.resource_prefix}-keypair"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_ssm_parameter" "private_key" {
  name        = "/ec2/keypair/${aws_key_pair.this.key_pair_id}"
  description = "SSH private key for ${local.resource_prefix} (used by setup-remote-ssh script)"
  type        = "SecureString"
  value       = tls_private_key.ssh.private_key_openssh

  tags = {
    Owner = var.username
  }
}
