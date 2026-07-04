variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "The AWS CLI profile to use"
  type        = string
  default     = "default"
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
}

variable "cluster_name" {
  description = "EKS cluster name, required if create_for_eks is true"
  type        = string
  default     = ""
}

variable "project" {
  description = "name of the project"
}

variable "team" {
  description = "name of the team"
}