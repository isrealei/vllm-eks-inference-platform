# Separate EFS access point for mistral's model cache — ReadWriteMany so
# future replicas share downloaded weights without re-downloading
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

resource "kubernetes_pod_disruption_budget_v1" "mistral" {
  metadata {
    name      = "mistral-7b"
    namespace = "default"
  }

  spec {
    max_unavailable = 1

    selector {
      match_labels = {
        app = "mistral-7b"
      }
    }
  }
}

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
      maxReplicaCount: 2
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

resource "kubectl_manifest" "mistral_deployment" {
  yaml_body = file("${path.module}/vllm/mistral-deployment.yaml")

  lifecycle {
    # Ignore all in-cluster drift (replicas managed by KEDA).
    # To force re-apply after a YAML change: terraform apply -replace=kubectl_manifest.mistral_deployment
    ignore_changes = [yaml_body]
  }

  depends_on = [
    kubernetes_secret.hf_token,
    kubernetes_persistent_volume_claim.hf_model2_cache,
    kubectl_manifest.mistral_service,
    kubectl_manifest.gpu_nodepool,
  ]
}
