# セキュリティグループ
# - 全インバウンド拒否 (接続は SSM SessionManager で、SSH ポートは開けない)
# - アウトバウンドは HTTPS/HTTP/DNS のみ

resource "aws_security_group" "this" {
  name        = "${local.resource_prefix}-sg"
  description = "Security group for ${var.username} workstation - All inbound blocked"
  vpc_id      = var.vpc_id

  tags = {
    Name  = "${local.resource_prefix}-sg"
    Owner = var.username
  }
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "Allow HTTPS outbound for SSM, git, docker, apt"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.this.id
  description       = "Allow HTTP outbound for package repositories"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  security_group_id = aws_security_group.this.id
  description       = "Allow DNS resolution"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}
