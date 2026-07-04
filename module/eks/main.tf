locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.team
  }
  eks_addons = {
    vpc-cni = {
      version = data.aws_eks_addon_version.default["vpc-cni"].version
    }
    coredns = {
      version = data.aws_eks_addon_version.default["coredns"].version
    }
    eks-pod-identity-agent = {
      version = data.aws_eks_addon_version.default["eks-pod-identity-agent"].version
    }
    kube-proxy = {
      version = data.aws_eks_addon_version.default["kube-proxy"].version
    }
  }
  eks_users = {
    admin = var.admin_user_arn
  }

}

# IAM Role for EKS Cluster
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-eks-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-eks-role"
    }
  )

}

# Attach the AmazonEKSClusterPolicy to the IAM role'
resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

#create EKS cluster

resource "aws_eks_cluster" "cluster" {
  name = var.cluster_name

  access_config {
    authentication_mode = "API"
  }

  role_arn = aws_iam_role.cluster.arn

  version = var.eks_version

  vpc_config {
    subnet_ids = var.subnet_ids
  }

  depends_on = [aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy]
  lifecycle {
    prevent_destroy = false
  }

  tags = merge(
    local.common_tags,
    {
      Name = var.cluster_name
    }
  )

}

# Add tags to the cluster security group for Karpenter discovery
resource "aws_ec2_tag" "karpenter_cluster_sg_discovery" {
  resource_id = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# data block to get the latest addon versions for the cluster version
data "aws_eks_addon_version" "default" {
  for_each           = toset(["coredns", "kube-proxy", "vpc-cni", "eks-pod-identity-agent"])
  addon_name         = each.key
  kubernetes_version = aws_eks_cluster.cluster.version
  most_recent        = true
}

# loop through addons and create them
resource "aws_eks_addon" "addons" {
  for_each = local.eks_addons

  cluster_name                = aws_eks_cluster.cluster.name
  addon_name                  = each.key
  addon_version               = each.value.version
  resolve_conflicts_on_update = "OVERWRITE"

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-${each.key}-addon"
    }
  )
}

# create I am role for node group

resource "aws_iam_role" "node_group" {
  name = "${var.cluster_name}-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-node-group-role"
    }
  )
}

resource "aws_iam_role_policy_attachment" "node_policy" {

  for_each = toset(
    [
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
      "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    ]
  )

  policy_arn = each.key
  role       = aws_iam_role.node_group.name

}


data "aws_ssm_parameter" "eks_ami_release_version" {
  name = "/aws/service/eks/optimized-ami/${aws_eks_cluster.cluster.version}/amazon-linux-2023/x86_64/standard/recommended/release_version"
}

resource "aws_eks_node_group" "node_group" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.cluster.name
  node_group_name = each.key
  version         = aws_eks_cluster.cluster.version
  release_version = nonsensitive(data.aws_ssm_parameter.eks_ami_release_version.value)
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids
  instance_types  = each.value.instance_types
  capacity_type   = each.value.capacity_type
  scaling_config {
    desired_size = each.value.scaling_config.desired_size
    max_size     = each.value.scaling_config.max_size
    min_size     = each.value.scaling_config.min_size
  }

  lifecycle {
    ignore_changes = [
      scaling_config[0].desired_size, # managed by Karpenter / cluster autoscaler
      release_version,                 # update AMI explicitly, not on every apply
    ]
  }

  depends_on = [aws_iam_role_policy_attachment.node_policy]

}


# create access entry to autheicate users
resource "aws_eks_access_entry" "policy" {
  for_each = local.eks_users

  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = each.value
  user_name     = each.key
}

resource "aws_eks_access_policy_association" "policy_association" {
  for_each      = local.eks_users
  cluster_name  = aws_eks_cluster.cluster.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value

  access_scope {
    type = "cluster"
  }

}




