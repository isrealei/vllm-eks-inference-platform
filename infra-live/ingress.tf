# -----------------------------------------------------------------------------
# AWS Load Balancer Controller — not the ingress controller itself; its only
# job here is provisioning/managing the NLB in front of Traefik's Service,
# since EKS 1.36 no longer supports in-tree LB provisioning. Uses EKS Pod
# Identity (no OIDC provider on this cluster), same pattern as Karpenter.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "aws_load_balancer_controller_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.aws_load_balancer_controller_assume.json
}

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${var.cluster_name}-aws-load-balancer-controller"
  policy = file("${path.module}/iam/aws-load-balancer-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.13.0"

  values = [
    yamlencode({
      clusterName = var.cluster_name
      region      = var.region
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
      }
    })
  ]

  depends_on = [aws_eks_pod_identity_association.aws_load_balancer_controller]
}

# -----------------------------------------------------------------------------
# Traefik — the actual ingress controller: terminates traffic, does host/path
# routing and TLS. Its Service gets an internet-facing NLB provisioned by the
# AWS Load Balancer Controller above via annotations.
# -----------------------------------------------------------------------------

resource "helm_release" "traefik" {
  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "34.5.0"

  values = [
    yamlencode({
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        }
      }
    })
  ]

  depends_on = [helm_release.aws_load_balancer_controller]
}
