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
