provider "aws" {
  region = var.aws_region

  default_tags {
    tags = module.config.default_tags
  }
}
