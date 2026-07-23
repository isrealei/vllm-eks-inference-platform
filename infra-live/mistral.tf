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

resource "kubectl_manifest" "mistral_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "mistral-7b"
      namespace = "default"
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
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "mistral-7b"
      namespace = "default"
      annotations = {
        "prometheus.io/scrape" = "true"
        "prometheus.io/port"   = "8000"
      }
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "mistral-7b" } }
      template = {
        metadata = { labels = { app = "mistral-7b" } }
        spec = {
          containers = [{
            name  = "vllm"
            image = "vllm/vllm-openai:v0.6.3"
            args = [
              "--model", "mistralai/Mistral-7B-Instruct-v0.3",
              "--tokenizer-mode", "mistral",
              "--dtype", "auto",
              "--quantization", "fp8",
              "--max-model-len", "4096",
              "--gpu-memory-utilization", "0.85",
              "--served-model-name", "mistral-7b",
            ]
            ports = [{ containerPort = 8000 }]
            env = [{
              name = "HUGGING_FACE_HUB_TOKEN"
              valueFrom = {
                secretKeyRef = {
                  name = kubernetes_secret.hf_token.metadata[0].name
                  key  = "token"
                }
              }
            }]
            resources = {
              limits   = { "nvidia.com/gpu" = "1", memory = "24Gi" }
              requests = { "nvidia.com/gpu" = "1", cpu = "4", memory = "16Gi" }
            }
            readinessProbe = {
              httpGet             = { path = "/health", port = 8000 }
              initialDelaySeconds = 60
              periodSeconds       = 10
              failureThreshold    = 30
            }
            livenessProbe = {
              httpGet             = { path = "/health", port = 8000 }
              initialDelaySeconds = 120
              periodSeconds       = 30
              failureThreshold    = 3
              timeoutSeconds      = 10
            }
            volumeMounts = [
              { name = "model-cache", mountPath = "/root/.cache/huggingface" },
              { name = "dshm",        mountPath = "/dev/shm" },
            ]
          }]
          nodeSelector = {
            "karpenter.sh/nodepool" = "gpu-inference"
          }
          tolerations = [{
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          }]
          volumes = [
            {
              name = "model-cache"
              persistentVolumeClaim = {
                claimName = kubernetes_persistent_volume_claim.hf_model2_cache.metadata[0].name
              }
            },
            {
              name     = "dshm"
              emptyDir = { medium = "Memory", sizeLimit = "8Gi" }
            },
          ]
        }
      }
    }
  })

  depends_on = [
    kubernetes_secret.hf_token,
    kubernetes_persistent_volume_claim.hf_model2_cache,
    kubectl_manifest.mistral_service,
    kubectl_manifest.gpu_nodepool,
  ]
}
