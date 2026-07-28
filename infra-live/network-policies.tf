# ---------------------------------------------------------------------------
# NetworkPolicies — default-deny ingress per namespace, explicit allow rules.
#
#   llm-gateway:
#     - litellm-proxy  ← Traefik (any source) + monitoring namespace on :4000
#     - postgres       ← litellm-proxy + postgres-backup pods on :5432 only
#     - redis          ← litellm-proxy pods on :6379 only
#
#   default:
#     - vllm-llama3    ← llm-gateway + monitoring namespaces on :8000
#     - mistral-7b     ← llm-gateway + monitoring namespaces on :8000
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "netpol_deny_ingress_llm_gateway" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny-ingress"
      namespace = local.litellm_ns
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress"]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# LiteLLM: accept from Traefik (any source) and Prometheus.
# The broad "any source" rule is intentional — Traefik terminates TLS and
# forwards on behalf of arbitrary external clients; restricting by source IP
# would break the NLB forwarding path.
resource "kubectl_manifest" "netpol_litellm_allow_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "litellm-allow-ingress"
      namespace = local.litellm_ns
    }
    spec = {
      podSelector = { matchLabels = { app = "litellm-proxy" } }
      policyTypes = ["Ingress"]
      ingress = [
        # External traffic forwarded by Traefik NLB
        { ports = [{ port = 4000, protocol = "TCP" }] },
        # Prometheus scraping from monitoring namespace
        {
          from  = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "monitoring" } } }]
          ports = [{ port = 4000, protocol = "TCP" }]
        },
      ]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# Postgres: only litellm-proxy and the backup CronJob pods may connect.
resource "kubectl_manifest" "netpol_postgres_allow_litellm" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "postgres-allow-litellm"
      namespace = local.litellm_ns
    }
    spec = {
      podSelector = { matchLabels = { app = "postgres" } }
      policyTypes = ["Ingress"]
      ingress = [{
        from = [
          { podSelector = { matchLabels = { app = "litellm-proxy" } } },
          { podSelector = { matchLabels = { app = "postgres-backup" } } },
        ]
        ports = [{ port = 5432, protocol = "TCP" }]
      }]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# Redis: only litellm-proxy may connect.
resource "kubectl_manifest" "netpol_redis_allow_litellm" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "redis-allow-litellm"
      namespace = local.litellm_ns
    }
    spec = {
      podSelector = { matchLabels = { app = "redis" } }
      policyTypes = ["Ingress"]
      ingress = [{
        from  = [{ podSelector = { matchLabels = { app = "litellm-proxy" } } }]
        ports = [{ port = 6379, protocol = "TCP" }]
      }]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# vLLM Llama 3: accept from llm-gateway (LiteLLM calls) and monitoring (Prometheus).
resource "kubectl_manifest" "netpol_vllm_llama3_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "vllm-llama3-allow-ingress"
      namespace = "default"
    }
    spec = {
      podSelector = { matchLabels = { app = "vllm-llama3" } }
      policyTypes = ["Ingress"]
      ingress = [{
        from = [
          { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "llm-gateway" } } },
          { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "monitoring" } } },
        ]
        ports = [{ port = 8000, protocol = "TCP" }]
      }]
    }
  })
}

# vLLM Mistral 7B: same pattern as Llama.
resource "kubectl_manifest" "netpol_mistral_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "mistral-allow-ingress"
      namespace = "default"
    }
    spec = {
      podSelector = { matchLabels = { app = "mistral-7b" } }
      policyTypes = ["Ingress"]
      ingress = [{
        from = [
          { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "llm-gateway" } } },
          { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "monitoring" } } },
        ]
        ports = [{ port = 8000, protocol = "TCP" }]
      }]
    }
  })
}
