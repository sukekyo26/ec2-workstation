module "config" {
  source = "../../modules/config"
}

module "network" {
  source = "../../modules/network"

  project_name       = module.config.project_name
  environment        = module.config.environment
  vpc_cidr           = module.config.vpc_cidr
  vpc_name           = module.config.vpc_name
  public_subnet_name = module.config.public_subnet_name
}
