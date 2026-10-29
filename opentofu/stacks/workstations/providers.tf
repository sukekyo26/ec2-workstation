provider "aws" {
  region = module.config.aws_region

  default_tags {
    tags = module.config.default_tags
  }
}
