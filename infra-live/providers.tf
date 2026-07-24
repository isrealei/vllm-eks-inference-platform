terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.42.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.1.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.1.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
  }
  required_version = "~>1.15.0"
  backend "s3" {
    bucket       = "amz-state-lock"
    key          = "prod/terraform.tfstate"
    use_lockfile = true
    region       = "us-east-1"
    profile      = "barilon"
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

locals {
  cluster_endpoint = module.eks.cluster_endpoint
  cluster_ca       = base64decode(module.eks.cluster_ca_certificate)
  exec_config = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region, "--profile", var.profile]
  }
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster_endpoint
    cluster_ca_certificate = local.cluster_ca
    exec                   = local.exec_config
  }
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca
  exec {
    api_version = local.exec_config.api_version
    command     = local.exec_config.command
    args        = local.exec_config.args
  }
}

provider "kubectl" {
  host                   = local.cluster_endpoint
  cluster_ca_certificate = local.cluster_ca
  exec {
    api_version = local.exec_config.api_version
    command     = local.exec_config.command
    args        = local.exec_config.args
  }
}
