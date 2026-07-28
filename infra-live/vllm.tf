# PriorityClass for GPU inference workloads. Ensures vLLM pods are scheduled
# before lower-priority jobs during node-level resource contention (e.g. when
# Karpenter is provisioning and multiple workloads compete for the first GPU slot).
resource "kubectl_manifest" "gpu_inference_priority_class" {
  yaml_body = yamlencode({
    apiVersion    = "scheduling.k8s.io/v1"
    kind          = "PriorityClass"
    metadata      = { name = "gpu-inference-critical" }
    value         = 900000
    globalDefault = false
    description   = "High priority for GPU inference workloads."
  })
}

# create kubernetes manifest for vLLM deployment on EKS with Karpenter GPU node pool
resource "kubectl_manifest" "vllm" {
  yaml_body = file("${path.module}/vllm/llama.yaml")

  lifecycle {
    # Ignore all in-cluster drift (replicas managed by KEDA).
    # To force re-apply after a YAML change: terraform apply -replace=kubectl_manifest.vllm
    ignore_changes = [yaml_body]
  }

  depends_on = [
    kubectl_manifest.gpu_nodepool,
    kubectl_manifest.gpu_nodeclass,
  ]
}


# create kubernetes secret to store Hugging Face API token for vLLM to pull models from Hugging Face Hub, and a PVC for model caching
resource "kubernetes_secret" "hf_token" {
  metadata {
    name      = "hf-token"
    namespace = "default"
  }

  data = {
    token = var.hf_token
  }

  type = "Opaque"
}


# Persistent Volume Claim for Llama model weight cache — backed by EFS (ReadWriteMany)
resource "kubernetes_persistent_volume_claim" "hf_model_cache" {
  metadata {
    name      = "hf-model-cache"
    namespace = "default"
  }
  spec {
    access_modes = ["ReadWriteMany"]

    resources {
      requests = {
        storage = "100Gi"
      }
    }

    storage_class_name = "efs-sc"
  }

  wait_until_bound = false

  depends_on = [kubernetes_storage_class_v1.efs]
}



resource "kubernetes_pod_disruption_budget_v1" "vllm_llama3" {
  metadata {
    name      = "vllm-llama3"
    namespace = "default"
  }

  spec {
    min_available = 1

    selector {
      match_labels = {
        app = "vllm-llama3"
      }
    }
  }
}


resource "kubernetes_service" "vllm_llama3" {
  metadata {
    name      = "vllm-llama3"
    namespace = "default"
    labels = {
      app = "vllm-llama3"
    }
  }

  spec {
    selector = {
      app = "vllm-llama3"
    }

    port {
      name        = "http" # ← ServiceMonitor references this
      port        = 80
      target_port = 8000
    }
  }
}


