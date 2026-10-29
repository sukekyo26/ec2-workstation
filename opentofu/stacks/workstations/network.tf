# network のルート (stacks/network) が作った VPC とサブネットを、Name タグで引く。
# network を apply する前は "no matching EC2 VPC found" で plan が止まる。

data "aws_vpc" "this" {
  tags = {
    Name = module.config.vpc_name
  }
}

data "aws_subnet" "public" {
  vpc_id = data.aws_vpc.this.id

  tags = {
    Name = module.config.public_subnet_name
  }
}
