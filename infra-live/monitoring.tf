resource "helm_release" "prometheus" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "70.4.2"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 300

  set = [
    {
      name  = "prometheus.prometheusSpec.retention"
      value = "15d"
    },

    {
      name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
      value = "gp3"
    },

    {
      name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]"
      value = "ReadWriteOnce"
    },

    {
      name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
      value = "50Gi"
    },

    {
      name  = "grafana.enabled"
      value = "true"
    },

    {
      name  = "grafana.adminPassword"
      value = var.grafana_password
    },

    {
      name  = "alertmanager.enabled"
      value = "true"
    }
  ]

  depends_on = [
    module.eks
  ]
}


resource "kubectl_manifest" "vllm_service_monitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: vllm-llama3
      namespace: monitoring
      labels:
        release: prometheus    # must match kube-prometheus-stack release name
    spec:
      namespaceSelector:
        matchNames:
          - default
      selector:
        matchLabels:
          app: vllm-llama3
      endpoints:
        - port: http
          path: /metrics
          interval: 30s
  YAML
}