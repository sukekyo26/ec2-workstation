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
  description        = "IAM role for ${var.username} workstation EC2 instance"
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
