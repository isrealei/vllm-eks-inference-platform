
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.16.1"
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 300

  depends_on = [module.eks]
}

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
        - metadata:
            metricName: vllm_gpu_cache_usage_perc
            query: avg(vllm:gpu_cache_usage_perc{model_name="llama3"}) * 100
            serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090
            threshold: "80"
          type: prometheus

        
  YAML

  depends_on = [helm_release.keda, helm_release.prometheus, kubectl_manifest.vllm]
}
