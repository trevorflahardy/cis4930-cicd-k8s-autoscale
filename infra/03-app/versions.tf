terraform {
  required_version = ">= 1.6"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.5"
    }
  }
}

data "terraform_remote_state" "platform" {
  backend = "local"
  config = {
    path = "${path.module}/../01-platform/terraform.tfstate"
  }
}

locals {
  platform = data.terraform_remote_state.platform.outputs
}

provider "kubernetes" {
  host                   = local.platform.endpoint
  client_certificate     = local.platform.client_certificate
  client_key             = local.platform.client_key
  cluster_ca_certificate = local.platform.cluster_ca_certificate
}
