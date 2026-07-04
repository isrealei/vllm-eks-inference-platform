
# helm chart to deploy NVIDIA GPU Operator and Karpenter node pool for GPU workloads on EKS
resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://helm.ngc.nvidia.com/nvidia"
  chart            = "gpu-operator"
  version          = "v26.3.1"
  namespace        = "gpu-operator"
  create_namespace = true
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "driver.enabled"
      value = "false" # AL2023 EKS GPU AMI already has drivers baked in
    },
    {
      name  = "toolkit.enabled"
      value = "true"
    },
    {
      name  = "dcgmExporter.enabled"
      value = "true"
    },
    {
      name  = "nfd.enabled"
      value = "true"
    }
  ]

  depends_on = [
    module.eks
  ]
}


