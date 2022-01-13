locals {
  vpc_region     = "{{ .VPCRegion }}"
  hvn_region     = "{{ .HVNRegion }}"
  cluster_id     = "{{ .ClusterID }}"
  hvn_id         = "{{ .ClusterID }}-hvn"
  hvn_cidr_block = "172.25.32.0/20"
  tier           = "development"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.43"
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = ">= 0.18.0"
    }
  }

}

provider "aws" {
  region = local.vpc_region
}

data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.10.0"

  name                 = "${local.cluster_id}-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = []
  public_subnets       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  enable_dns_hostnames = true
}

resource "hcp_hvn" "main" {
  hvn_id         = local.hvn_id
  cloud_provider = "aws"
  region         = local.hvn_region
  cidr_block     = local.hvn_cidr_block
}

module "aws_hcp_consul" {
  source  = "hashicorp/hcp-consul/aws"
  version = "~> 0.4.1"

  hvn             = hcp_hvn.main
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.public_subnets
  route_table_ids = module.vpc.public_route_table_ids
}

resource "hcp_consul_cluster" "main" {
  cluster_id      = local.cluster_id
  hvn_id          = hcp_hvn.main.hvn_id
  public_endpoint = true
  tier            = local.tier
}

resource "hcp_consul_cluster_root_token" "token" {
  cluster_id = hcp_consul_cluster.main.id
}

module "aws_ec2_consul_client" {
  source  = "hashicorp/hcp-consul/aws//modules/hcp-ec2-client"
  version = "~> 0.4.1"

  subnet_id                = module.vpc.public_subnets[0]
  security_group_id        = module.aws_hcp_consul.security_group_id
  allowed_ssh_cidr_blocks  = ["0.0.0.0/0"]
  allowed_http_cidr_blocks = ["0.0.0.0/0"]
  client_config_file       = hcp_consul_cluster.main.consul_config_file
  client_ca_file           = hcp_consul_cluster.main.consul_ca_file
  root_token               = hcp_consul_cluster_root_token.token.secret_id
  consul_version           = hcp_consul_cluster.main.consul_version

  depends_on = [module.aws_hcp_consul]
}
output "consul_root_token" {
  value     = hcp_consul_cluster_root_token.token.secret_id
  sensitive = true
}

output "consul_url" {
  value = hcp_consul_cluster.main.public_endpoint ? (
    hcp_consul_cluster.main.consul_public_endpoint_url
    ) : (
    hcp_consul_cluster.main.consul_private_endpoint_url
  )
}

output "nomad_url" {
  value = "http://${module.aws_ec2_consul_client.host_dns}:8081"
}

output "hashicups_url" {
  value = "http://${module.aws_ec2_consul_client.host_dns}"
}
