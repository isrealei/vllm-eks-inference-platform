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
}

variable "team" {
  description = "team name"
}

variable "eks_version" {
  description = "The version of EKS to use"
  type        = string
}


variable "eks_vpc_cni_version" {
  description = "The version of the VPC CNI addon to use"
  type        = string
  default     = "v1.21.1-eksbuild.7"
}

variable "eks_coredns_version" {
  description = "The version of the CoreDNS addon to use"
  type        = string
  default     = "v1.14.2-eksbuild.4"
}

variable "eks_pod_identity_agent_version" {
  description = "eks pod identity version"
  type        = string
  default     = "v1.3.10-eksbuild.3"
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