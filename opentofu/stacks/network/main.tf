module "config" {
  source = "../../modules/config"
}

module "network" {
  source = "../../modules/network"

  resource_prefix    = module.config.resource_prefix
  vpc_cidr           = module.config.vpc_cidr
  vpc_name           = module.config.vpc_name
  public_subnet_name = module.config.public_subnet_name
}
