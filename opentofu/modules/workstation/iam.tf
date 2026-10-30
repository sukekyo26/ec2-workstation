# インスタンスの IAM ロール / インスタンスプロファイル
# - SSM SessionManager で接続するための AmazonSSMManagedInstanceCore
# - 秘密鍵 (keypair.tf) の値を読む道を拒む Deny

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
  name                 = "${local.resource_prefix}-instance-role"
  description          = "IAM role for ${var.username} workstation EC2 instance"
  assume_role_policy   = data.aws_iam_policy_document.instance_assume.json
  permissions_boundary = local.permissions_boundary_arn

  tags = {
    Owner = var.username
  }
}

# LIMIT: 管理ポリシーを足したら、その Action と名前の Sid を cloudformation/permissions-boundary.yaml にも足す (opentofu/stacks/workstations/tests/boundary.tftest.hcl が CI で見る。Resource の広さは見ない)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# インスタンスの中では秘密鍵 (自分のものも) を使わないので、値を読む道を全部拒む (opentofu/stacks/workstations/tests/boundary.tftest.hcl が確かめる)
data "aws_iam_policy_document" "deny_keypair_read" {
  statement {
    effect    = "Deny"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
    resources = ["arn:*:ssm:*:*:parameter${local.keypair_parameter_prefix}*"]
  }
  # パスで引くと、IAM はパスの ARN で評価しうるので、Resource を絞らない
  statement {
    effect    = "Deny"
    actions   = ["ssm:GetParametersByPath"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deny_keypair_read" {
  name   = "deny-keypair-read"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.deny_keypair_read.json
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.resource_prefix}-instance-profile"
  role = aws_iam_role.instance.name
}
