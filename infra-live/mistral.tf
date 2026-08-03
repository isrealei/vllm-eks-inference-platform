# EFS-backed PVC for Mistral weight cache — ReadWriteMany lets all replicas share
# the downloaded model files so scale-out pods skip the multi-GB HuggingFace download.
resource "kubernetes_persistent_volume_claim" "hf_model2_cache" {
  metadata {
    name      = "hf-model2-cache"
    namespace = "default"
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = "efs-sc"
    resources {
      requests = {
        storage = "100Gi"
      }
    }
  }

  wait_until_bound = false

  depends_on = [kubernetes_storage_class_v1.efs]
}

# Guarantees at least 1 Mistral pod stays running during node drain or rolling update,
# preventing a complete service outage while KEDA scales or Karpenter recycles nodes.
resource "kubernetes_pod_disruption_budget_v1" "mistral" {
  metadata {
    name      = "mistral-7b"
    namespace = "default"
  }

  spec {
    min_available = 1

    selector {
      match_labels = {
        app = "mistral-7b"
      }
    }
  }
}

# ClusterIP service that gives LiteLLM a stable DNS name to reach the inference pods.
# Port 8000 is vLLM's default HTTP port; the named port "http" is referenced by the
# ServiceMonitor and the KEDA ScaledObject below.
resource "kubectl_manifest" "mistral_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "mistral-7b"
      namespace = "default"
      labels    = { app = "mistral-7b" }
    }
    spec = {
      selector = { app = "mistral-7b" }
      ports    = [{ name = "http", port = 8000, targetPort = 8000 }]
    }
  })
}

# Tells Prometheus to scrape vLLM's /metrics endpoint every 30s.
# Lives in the monitoring namespace so kube-prometheus-stack discovers it via
# the release=prometheus label selector on the Prometheus CR.
resource "kubectl_manifest" "mistral_service_monitor" {
  yaml_body = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "ServiceMonitor"
    metadata = {
      name      = "mistral-7b"
      namespace = "monitoring"
      labels = {
        release = "prometheus"
      }
    }
    spec = {
      namespaceSelector = {
        matchNames = ["default"]
      }
      selector = {
        matchLabels = { app = "mistral-7b" }
      }
      endpoints = [{
        port     = "http"
        path     = "/metrics"
        interval = "30s"
      }]
    }
  })

  depends_on = [helm_release.prometheus, kubectl_manifest.mistral_service]
}

# KEDA ScaledObject that drives Mistral autoscaling based on two Prometheus signals:
#   1. Queue depth  — scale out when >5 requests are waiting for a GPU slot.
#   2. KV cache use — scale out when GPU memory blocks are >80% occupied,
#      indicating the model is under long-context pressure.
# Replicas are bounded 1–4 matching the GPU NodePool limit in karpenter/nodepool-gpu.yaml.
resource "kubectl_manifest" "mistral_scaled_object" {
  yaml_body = <<-YAML
    apiVersion: keda.sh/v1alpha1
    kind: ScaledObject
    metadata:
      name: mistral-7b
      namespace: default
    spec:
      scaleTargetRef:
        name: mistral-7b
      minReplicaCount: 1
      maxReplicaCount: 4
      pollingInterval: 30
      cooldownPeriod: 300
      triggers:
        - type: prometheus
          metadata:
            serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
            metricName: vllm_num_requests_waiting_mistral
            query: sum(vllm:num_requests_waiting{namespace="default",model_name="mistral-7b"})
            threshold: "5"
        - type: prometheus
          metadata:
            serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
            metricName: vllm_gpu_cache_usage_mistral
            query: avg(vllm:gpu_cache_usage_perc{namespace="default",model_name="mistral-7b"}) * 100
            threshold: "80"
  YAML

  depends_on = [helm_release.keda, helm_release.prometheus, kubectl_manifest.mistral_deployment]
}

# Mistral-7B deployment manifest loaded from the vllm/ directory.
# ignore_changes prevents Terraform from fighting KEDA over the replica count —
# KEDA owns replicas at runtime; Terraform owns the pod spec.
# To force a re-apply after editing mistral-deployment.yaml:
#   terraform apply -replace=kubectl_manifest.mistral_deployment
resource "kubectl_manifest" "mistral_deployment" {
  yaml_body = file("${path.module}/vllm/mistral-deployment.yaml")

  lifecycle {
    ignore_changes = [yaml_body]
  }

  depends_on = [
    kubernetes_secret.hf_token,
    kubernetes_persistent_volume_claim.hf_model2_cache,
    kubectl_manifest.mistral_service,
    kubectl_manifest.gpu_nodepool,
  ]
}
