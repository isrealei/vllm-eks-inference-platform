locals {
  openwebui_ns = "openwebui"
}

resource "kubernetes_namespace_v1" "openwebui" {
  metadata {
    name = local.openwebui_ns
  }
}

# Session-signing key and LiteLLM credential kept out of the Helm values so they
# never appear in plain-text in the Terraform state chart diff.
resource "kubernetes_secret" "openwebui" {
  metadata {
    name      = "openwebui-secrets"
    namespace = local.openwebui_ns
  }

  data = {
    # Used by OpenWebUI to sign JWTs — must be stable across pod restarts.
    webui-secret-key = var.webui_secret_key
    # Passed as OPENAI_API_KEY so OpenWebUI authenticates against LiteLLM.
    openai-api-key = var.litellm_master_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace_v1.openwebui]
}

# OpenWebUI deployed from the official Helm chart.
# Ollama is disabled — the only backend is the internal LiteLLM proxy, which
# exposes all vLLM models under the standard OpenAI-compatible /v1 endpoint.
resource "helm_release" "openwebui" {
  name             = "openwebui"
  repository       = "https://open-webui.github.io/helm-charts"
  chart            = "open-webui"
  namespace        = local.openwebui_ns
  create_namespace = false
  wait             = true
  timeout          = 300

  set = [
    # Disable bundled Ollama — all inference goes through LiteLLM.
    { name = "ollama.enabled", value = "false" },
    # Disable Ollama API endpoint in the UI entirely.
    { name = "enableOllamaApi", value = "false" },
    # Pipelines is optional Python middleware — not needed for vLLM integration.
    { name = "pipelines.enabled", value = "false" },
    # gp3 PVC for chat history, uploaded files, and vector embeddings.
    { name = "persistence.enabled", value = "true" },
    { name = "persistence.storageClass", value = "gp3" },
    { name = "persistence.size", value = "10Gi" },
    # Ingress is managed as a separate kubectl_manifest below (Traefik + cert-manager).
    { name = "ingress.enabled", value = "false" },
  ]

  values = [yamlencode({
    extraEnvVars = [
      # Route all model calls to the internal LiteLLM proxy.
      {
        name  = "OPENAI_API_BASE_URL"
        value = "http://litellm-proxy.${local.litellm_ns}.svc.cluster.local/v1"
      },
      # Authenticate against LiteLLM using the master key.
      {
        name = "OPENAI_API_KEY"
        valueFrom = {
          secretKeyRef = {
            name = kubernetes_secret.openwebui.metadata[0].name
            key  = "openai-api-key"
          }
        }
      },
      # Signs JWTs for user sessions — must be stable across restarts.
      {
        name = "WEBUI_SECRET_KEY"
        valueFrom = {
          secretKeyRef = {
            name = kubernetes_secret.openwebui.metadata[0].name
            key  = "webui-secret-key"
          }
        }
      },
    ]
  })]

  depends_on = [
    kubernetes_namespace_v1.openwebui,
    kubernetes_secret.openwebui,
    kubectl_manifest.litellm_deployment,
  ]
}

# Traefik ingress with TLS termination via cert-manager Let's Encrypt.
# The service name matches the Helm release name (openwebui).
resource "kubectl_manifest" "openwebui_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "openwebui"
      namespace = local.openwebui_ns
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      }
    }
    spec = {
      ingressClassName = "traefik"
      tls = [{
        hosts      = ["chat.${var.dns_zone_name}"]
        secretName = "openwebui-tls"
      }]
      rules = [{
        host = "chat.${var.dns_zone_name}"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "openwebui-open-webui"
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
    helm_release.openwebui,
  ]
}
