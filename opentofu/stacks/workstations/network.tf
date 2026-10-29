# network のルート (stacks/network) が作った VPC とサブネットを、Name タグで引く。
# network を apply する前は "no matching EC2 VPC found" で plan が止まる。

data "aws_vpc" "this" {
  tags = {
    Name = module.config.vpc_name
  }

  # ユーザーの workspace でだけ plan させる (default や打ち間違いの workspace に state を作らない)。
  # data source に置くのは、validate では評価されず、-refresh=false の destroy の plan (設定から消えたユーザー) では読まれないため
  lifecycle {
    precondition {
      condition     = terraform.workspace != "default" && contains(keys(module.config.users), terraform.workspace)
      error_message = "Workspace \"${terraform.workspace}\" is not a username in workstation-config.json. Select a user's workspace with scripts/tofu-init.sh workstations <username>. To remove a user deleted from the config, run scripts/tofu-deploy.sh."
    }
  }
}

data "aws_subnet" "public" {
  vpc_id = data.aws_vpc.this.id

  tags = {
    Name = module.config.public_subnet_name
  }
}
