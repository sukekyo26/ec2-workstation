# 個人用ワークスペース (CDK: WorkspaceStack の Security/Ec2 construct と同等)
# - SG: 全インバウンド拒否、アウトバウンドは HTTPS/HTTP/DNS のみ
# - SSM SessionManager 接続 (SSH ポート非開放)
# - Ubuntu 24.04 LTS / EBS 暗号化 / IMDSv2 強制

locals {
  resource_prefix = "${var.project_name}-${var.environment}-${var.username}"
}

# ============================================================
# Security Group
# ============================================================

resource "aws_security_group" "this" {
  name        = "${local.resource_prefix}-sg"
  description = "Security group for ${var.username} workspace - All inbound blocked"
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

# ============================================================
# SessionManager ログ用 CloudWatch Logs
# ============================================================

resource "aws_cloudwatch_log_group" "session_logs" {
  name              = "/ssm/session-logs/${local.resource_prefix}"
  retention_in_days = 30
}

# ============================================================
# IAM Role / Instance Profile
# ============================================================

data "aws_iam_policy_document" "instance_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.resource_prefix}-instance-role"
  description        = "IAM role for ${var.username} workspace EC2 instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json

  tags = {
    Owner = var.username
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "session_logs_write" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.session_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "session_logs_write" {
  name   = "session-logs-write"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.session_logs_write.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.resource_prefix}-instance-profile"
  role = aws_iam_role.instance.name
}

# ============================================================
# EC2 Instance
# ============================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "this" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  key_name                    = aws_key_pair.this.key_name
  user_data                   = var.user_data
  associate_public_ip_address = true

  # IMDSv2 強制 (SSRF 対策)
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = var.volume_type
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name     = "${local.resource_prefix}-instance"
    Owner    = var.username
    Schedule = "office-hours"
  }

  lifecycle {
    # AMI は初回 apply 時に解決し以後固定する (CDK の cdk.context.json
    # キャッシュと同等の挙動。新 AMI 公開でインスタンスを再作成させない)
    ignore_changes = [ami]
  }
}

# ============================================================
# Elastic IP (オプション)
# ============================================================

resource "aws_eip" "this" {
  count  = var.enable_elastic_ip ? 1 : 0
  domain = "vpc"

  tags = {
    Name  = "${local.resource_prefix}-eip"
    Owner = var.username
  }
}

resource "aws_eip_association" "this" {
  count         = var.enable_elastic_ip ? 1 : 0
  allocation_id = aws_eip.this[0].id
  instance_id   = aws_instance.this.id
}
