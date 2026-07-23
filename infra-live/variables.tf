variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "The AWS CLI profile to use"
  type        = string
  default     = "barilon2"
}

variable "vpc_cidr" {
  description = "vpc cidr block"
  type        = string
}

variable "azs" {
  description = "vpc availability zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "public subnet cidr blocks"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "private subnet cidr blocks"
  type        = list(string)
}

variable "vpc_name" {
  description = "VPC name"
  type        = string
}

variable "environment" {
  description = "The environment to deploy resources in"
  type        = string
}

variable "create_for_eks" {
  description = "is this vpc for an eks cluster"
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "EKS cluster name, required if create_for_eks is true"
  type        = string
  default     = ""
}

# eks variables

variable "project" {
  description = "project name"
  type        = string
}

variable "team" {
  description = "team name"
  type        = string
}

variable "eks_version" {
  description = "The version of EKS to use"
  type        = string
}


variable "node_groups" {
  description = "Map of node group configurations"
  type = map(object({
    instance_types = list(string)
    capacity_type  = string
    scaling_config = object({
      desired_size = number
      max_size     = number
      min_size     = number
    })
  }))
}



variable "admin_user_arn" {
  description = "admin user arn"
  type        = string
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint — restrict to your corporate/VPN ranges in production"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}


variable "hf_token" {
  description = "Hugging Face API token"
  type        = string
  sensitive   = true
}

variable "grafana_password" {
  description = "Grafana admin password"
  type        = string
  sensitive   = true
}


variable "acme_email" {
  description = "email address for the acme dns challenge"
  type = string
}


variable "dns_zone_name" {
  description = "Route53 hosted zone used for cert-manager DNS-01 challenges"
  type        = string
}

variable "litellm_master_key" {
  description = "LiteLLM master API key — used to authenticate requests to the proxy"
  type        = string
  sensitive   = true
}

variable "litellm_pg_password" {
  description = "PostgreSQL password for the LiteLLM database user"
  type        = string
  sensitive   = true
}

variable "litellm_openai_api_key" {
  description = "OpenAI API key for external model access (set to 'none' if not used)"
  type        = string
  sensitive   = true
  default     = "none"
}