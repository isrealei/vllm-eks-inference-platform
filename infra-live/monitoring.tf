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
      name  = "alertmanager.enabled"
      value = "true"
    },
  ]

  set_sensitive = [
    {
      name  = "grafana.adminPassword"
      value = var.grafana_password
    },
  ]

  depends_on = [
    module.eks
  ]
}


resource "kubectl_manifest" "grafana_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "grafana"
      namespace = "monitoring"
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      }
    }
    spec = {
      ingressClassName = "traefik"
      tls = [{
        hosts      = ["grafana.${var.dns_zone_name}"]
        secretName = "grafana-tls"
      }]
      rules = [{
        host = "grafana.${var.dns_zone_name}"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "prometheus-grafana"
                port = { number = 80 }
              }
            }
          }]
        }
      }]
    }
  })

  depends_on = [
    kubectl_manifest.letsencrypt_prod,
    helm_release.traefik,
    helm_release.prometheus,
  ]
}
