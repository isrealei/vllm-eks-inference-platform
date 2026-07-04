output "vpc_id" {
  value = module.vpc.vpc_id
}

output "subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "debug_profile" {
  value = var.profile
}