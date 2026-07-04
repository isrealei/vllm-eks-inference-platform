variable "project" {
  description = "project name"
}

variable "team" {
  description = "team name"
}

variable "environment" {
  description = "The environment to deploy resources in"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "eks_version" {
  description = "The version of EKS to use"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster"
  type        = list(string)
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