data "aws_caller_identity" "current" {}


module "vpc" {
  source = "../module/networking"

  vpc_name             = var.vpc_name
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  environment          = var.environment
  create_for_eks       = var.create_for_eks
  cluster_name         = var.cluster_name
  project              = var.project
  team                 = var.team
}

module "eks" {
  source = "../module/eks"

  cluster_name      = var.cluster_name
  eks_version       = var.eks_version
  subnet_ids        = module.vpc.private_subnet_ids
  project           = var.project
  team              = var.team
  environment       = var.environment
  admin_user_arn    = var.admin_user_arn
  node_groups       = var.node_groups
  api_allowed_cidrs = var.api_allowed_cidrs

  depends_on = [module.vpc]

}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.19.0"


  cluster_name        = module.eks.cluster_name
  create_access_entry = true
  namespace           = "karpenter"


  # Attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }

  depends_on = [module.eks]
}