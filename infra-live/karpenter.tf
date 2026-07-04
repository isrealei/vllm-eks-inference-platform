resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter/"
  chart            = "karpenter"
  version          = "1.6.0"
  create_namespace = true

  values = [
    templatefile("${path.module}/karpenter/values.yaml.tpl", {
      service_account_name = module.karpenter.service_account
      cluster_name         = module.eks.cluster_name
      cluster_endpoint     = module.eks.cluster_endpoint
      queue_name           = module.karpenter.queue_name
    })
  ]
}

resource "kubectl_manifest" "default_nodepool" {
  yaml_body = file("${path.module}/karpenter/nodepool-default.yaml")
}

resource "kubectl_manifest" "default_nodeclass" {
  yaml_body = templatefile("${path.module}/karpenter/nodeclass-default.yaml.tpl", {
    CLUSTER_NAME = module.eks.cluster_name
    CLUSTER_ROLE = module.karpenter.node_iam_role_name
  })
}

resource "kubectl_manifest" "gpu_nodepool" {
  yaml_body = file("${path.module}/karpenter/nodepool-gpu.yaml")
}

resource "kubectl_manifest" "gpu_nodeclass" {
  yaml_body = templatefile("${path.module}/karpenter/nodeclass-gpu.yaml.tpl", {
    CLUSTER_NAME = module.eks.cluster_name
    NODE_ROLE    = module.karpenter.node_iam_role_name
  })
}
