
# Security group allowing NFS from within the VPC
resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow NFS inbound from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-efs-sg"
  }
}

resource "aws_efs_file_system" "model_cache" {
  encrypted = true

  tags = {
    Name = "${var.cluster_name}-vllm-model-cache"
  }
}

# One mount target per private subnet so every AZ can reach EFS
resource "aws_efs_mount_target" "model_cache" {
  count = length(module.vpc.private_subnet_ids)

  file_system_id  = aws_efs_file_system.model_cache.id
  subnet_id       = module.vpc.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# IAM role for the EFS CSI driver controller (Pod Identity)
resource "aws_iam_role" "efs_csi_driver" {
  name = "${var.cluster_name}-efs-csi-driver"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  role       = aws_iam_role.efs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_eks_addon" "efs_csi_driver" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-efs-csi-driver"
  addon_version               = "v3.3.0-eksbuild.1"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks, aws_iam_role_policy_attachment.efs_csi_driver]
}

resource "aws_eks_pod_identity_association" "efs_csi_driver" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.efs_csi_driver.arn
}

resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner    = "efs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = false

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.model_cache.id
    directoryPerms   = "700"
  }

  depends_on = [aws_eks_addon.efs_csi_driver]
}
