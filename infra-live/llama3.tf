# PriorityClass for GPU inference workloads. Ensures vLLM pods are scheduled
# before lower-priority jobs during node-level resource contention — e.g. when
# Karpenter is provisioning and multiple workloads compete for the first GPU slot.
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

# Llama 3.1 8B AWQ deployment manifest loaded from the vllm/ directory.
# ignore_changes prevents Terraform from fighting KEDA over the replica count —
# KEDA owns replicas at runtime; Terraform owns the pod spec.
# To force a re-apply after editing llama.yaml:
#   terraform apply -replace=kubectl_manifest.vllm
resource "kubectl_manifest" "vllm" {
  yaml_body = file("${path.module}/vllm/llama.yaml")

  lifecycle {
    ignore_changes = [yaml_body]
  }

  depends_on = [
    kubectl_manifest.gpu_nodepool,
    kubectl_manifest.gpu_nodeclass,
  ]
}

# HuggingFace token injected as a Kubernetes secret so vLLM can pull gated models
# (Llama 3.1 requires accepting Meta's licence before downloading).
# Value sourced from terraform.tfvars — never hardcoded.
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

# EFS-backed PVC for Llama weight cache — ReadWriteMany lets all replicas share
# the downloaded model files so scale-out pods skip the multi-GB HuggingFace download.
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

# Guarantees at least 1 Llama pod stays running during node drain or rolling update,
# preventing a complete service outage while KEDA scales or Karpenter recycles nodes.
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

# ClusterIP service that gives LiteLLM a stable DNS name to reach the inference pods.
# Port 80 → 8000 (vLLM's default HTTP port). The named port "http" is referenced
# by the ServiceMonitor and the KEDA ScaledObject below.
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
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

# Tells Prometheus to scrape vLLM's /metrics endpoint every 30s.
# Lives in the monitoring namespace so kube-prometheus-stack discovers it via
# the release=prometheus label selector on the Prometheus CR.
resource "kubectl_manifest" "vllm_llama3_service_monitor" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "vllm-llama3"
      namespace = "monitoring"
      labels    = { release = "prometheus" }
    }
    spec = {
      namespaceSelector = {
        matchNames = ["default"]
      }
      selector = {
        matchLabels = { app = "vllm-llama3" }
      }
      endpoints = [{
        port     = "http"
        path     = "/metrics"
        interval = "30s"
      }]
    }
  })

  depends_on = [helm_release.prometheus, kubernetes_service.vllm_llama3]
}

# KEDA ScaledObject that drives Llama autoscaling based on two Prometheus signals:
#   1. Queue depth  — scale out when >5 requests are waiting for a GPU slot.
#   2. KV cache use — scale out when GPU memory blocks are >80% occupied,
#      indicating the model is under long-context pressure.
# Replicas are bounded 1–4 matching the GPU NodePool limit in karpenter/nodepool-gpu.yaml.
resource "kubectl_manifest" "vllm_scaled_object" {
  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: vllm-llama3
      namespace: default
    spec:
      scaleTargetRef:
        name: vllm-llama3
      minReplicaCount: 1
      maxReplicaCount: 4
      pollingInterval: 30
      cooldownPeriod: 300
      triggers:
        - type: prometheus
          metadata:
            serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
            metricName: vllm_num_requests_waiting
            query: sum(vllm:num_requests_waiting{namespace="default",model_name="llama3"})
            threshold: "5"
        - type: prometheus
          metadata:
            serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
            metricName: vllm_gpu_cache_usage_perc
            query: avg(vllm:gpu_cache_usage_perc{namespace="default",model_name="llama3"}) * 100
            threshold: "80"
  YAML

  depends_on = [helm_release.keda, helm_release.prometheus, kubectl_manifest.vllm]
}
