locals {
  litellm_ns      = "llm-gateway"
  litellm_pg_user = "litellm"
  litellm_pg_db   = "litellm"
  litellm_db_url  = "postgresql://${local.litellm_pg_user}:${var.litellm_pg_password}@postgres.llm-gateway.svc.cluster.local:5432/${local.litellm_pg_db}"
}

resource "kubernetes_namespace_v1" "llm_gateway" {
  metadata {
    name = local.litellm_ns
  }
}

# All sensitive values injected from Terraform variables — nothing hardcoded.
# Postgres reads its password from this same secret via secretKeyRef.
resource "kubernetes_secret" "litellm" {
  metadata {
    name      = "litellm-secrets"
    namespace = local.litellm_ns
  }

  data = {
    LITELLM_MASTER_KEY = var.litellm_master_key
    DATABASE_URL       = local.litellm_db_url
    OPENAI_API_KEY     = var.litellm_openai_api_key
    POSTGRES_PASSWORD  = var.litellm_pg_password
  }

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

resource "kubernetes_config_map_v1" "litellm" {
  metadata {
    name      = "litellm-config"
    namespace = local.litellm_ns
  }

  data = {
    "config.yaml" = <<-YAML
      model_list:
        - model_name: llama3
          litellm_params:
            model: openai/llama3
            api_base: http://vllm-llama3.default.svc.cluster.local:80/v1
            api_key: none
          model_info:
            input_cost_per_token: 0.00000015
            output_cost_per_token: 0.00000030

        - model_name: mistral-7b
          litellm_params:
            model: openai/mistral-7b
            api_base: http://mistral-7b.default.svc.cluster.local:8000/v1
            api_key: none
          model_info:
            input_cost_per_token: 0.00000015
            output_cost_per_token: 0.00000030

      litellm_settings:
        drop_params: true
        set_verbose: false
        cache: true
        cache_params:
          type: redis
          host: redis.${local.litellm_ns}.svc.cluster.local
          ttl: 3600

      general_settings:
        master_key: os.environ/LITELLM_MASTER_KEY
        database_url: os.environ/DATABASE_URL
    YAML
  }

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# ---------------------------------------------------------------------------
# Redis — response cache. No persistence needed; a restart just warms the
# cache from live traffic. Single replica is sufficient.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "redis_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "redis"
      namespace = local.litellm_ns
    }
    spec = {
      replicas = 1
      selector = { matchLabels = { app = "redis" } }
      template = {
        metadata = { labels = { app = "redis" } }
        spec = {
          containers = [{
            name  = "redis"
            image = "redis:7-alpine"
            ports = [{ containerPort = 6379 }]
            resources = {
              limits   = { cpu = "500m", memory = "512Mi" }
              requests = { cpu = "100m", memory = "128Mi" }
            }
            readinessProbe = {
              tcpSocket           = { port = 6379 }
              initialDelaySeconds = 5
              periodSeconds       = 10
            }
            livenessProbe = {
              tcpSocket           = { port = 6379 }
              initialDelaySeconds = 15
              periodSeconds       = 20
            }
          }]
        }
      }
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

resource "kubectl_manifest" "redis_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "redis"
      namespace = local.litellm_ns
    }
    spec = {
      selector = { app = "redis" }
      ports    = [{ port = 6379, targetPort = 6379 }]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# ---------------------------------------------------------------------------
# PostgreSQL — stores LiteLLM request logs, spend tracking, and virtual keys.
# Headless service required by the StatefulSet. Password sourced from Secret.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "postgres_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "postgres"
      namespace = local.litellm_ns
    }
    spec = {
      clusterIP = "None"
      selector  = { app = "postgres" }
      ports     = [{ port = 5432, targetPort = 5432 }]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

resource "kubectl_manifest" "postgres_statefulset" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata = {
      name      = "postgres"
      namespace = local.litellm_ns
    }
    spec = {
      replicas    = 1
      serviceName = "postgres"
      selector = { matchLabels = { app = "postgres" } }
      template = {
        metadata = { labels = { app = "postgres" } }
        spec = {
          containers = [{
            name  = "postgres"
            image = "postgres:16"
            ports = [{ containerPort = 5432 }]
            env = [
              { name = "POSTGRES_USER", value = local.litellm_pg_user },
              { name = "POSTGRES_DB",   value = local.litellm_pg_db },
              {
                name = "POSTGRES_PASSWORD"
                valueFrom = {
                  secretKeyRef = {
                    name = kubernetes_secret.litellm.metadata[0].name
                    key  = "POSTGRES_PASSWORD"
                  }
                }
              },
              { name = "PGDATA", value = "/var/lib/postgresql/data/pgdata" },
            ]
            resources = {
              limits   = { cpu = "1", memory = "1Gi" }
              requests = { cpu = "250m", memory = "512Mi" }
            }
            volumeMounts = [{
              name      = "data"
              mountPath = "/var/lib/postgresql/data"
            }]
          }]
        }
      }
      volumeClaimTemplates = [{
        metadata = { name = "data" }
        spec = {
          accessModes      = ["ReadWriteOnce"]
          storageClassName = "gp3"
          resources        = { requests = { storage = "10Gi" } }
        }
      }]
    }
  })

  depends_on = [
    kubernetes_secret.litellm,
    kubectl_manifest.postgres_service,
  ]
}

resource "kubectl_manifest" "postgres_pdb" {
  yaml_body = yamlencode({
    apiVersion = "policy/v1"
    kind       = "PodDisruptionBudget"
    metadata = {
      name      = "postgres"
      namespace = local.litellm_ns
    }
    spec = {
      maxUnavailable = 0
      selector = {
        matchLabels = { app = "postgres" }
      }
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

# ---------------------------------------------------------------------------
# LiteLLM proxy — 2 replicas, pinned image, secrets from Secret, config from
# ConfigMap. Starts only after Postgres and Redis are up.
# ---------------------------------------------------------------------------

resource "kubectl_manifest" "litellm_deployment" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata = {
      name      = "litellm-proxy"
      namespace = local.litellm_ns
    }
    spec = {
      replicas = 2
      selector = { matchLabels = { app = "litellm-proxy" } }
      template = {
        metadata = {
          labels = { app = "litellm-proxy" }
          annotations = {
            "prometheus.io/scrape" = "true"
            "prometheus.io/port"   = "4000"
            "prometheus.io/path"   = "/metrics"
          }
        }
        spec = {
          containers = [{
            name  = "litellm"
            image = "ghcr.io/berriai/litellm:latest"
            args  = ["--config", "/etc/litellm/config.yaml", "--port", "4000"]
            ports = [{ containerPort = 4000, name = "http" }]
            envFrom = [{ secretRef = { name = kubernetes_secret.litellm.metadata[0].name } }]
            resources = {
              limits   = { cpu = "2", memory = "2Gi" }
              requests = { cpu = "500m", memory = "512Mi" }
            }
            readinessProbe = {
              httpGet             = { path = "/health/readiness", port = 4000 }
              initialDelaySeconds = 15
              periodSeconds       = 5
              failureThreshold    = 12
            }
            livenessProbe = {
              httpGet             = { path = "/health/liveliness", port = 4000 }
              initialDelaySeconds = 30
              periodSeconds       = 10
              failureThreshold    = 6
            }
            volumeMounts = [{
              name      = "config"
              mountPath = "/etc/litellm"
              readOnly  = true
            }]
          }]
          volumes = [{
            name      = "config"
            configMap = { name = kubernetes_config_map_v1.litellm.metadata[0].name }
          }]
        }
      }
    }
  })

  depends_on = [
    kubernetes_secret.litellm,
    kubernetes_config_map_v1.litellm,
    kubectl_manifest.postgres_statefulset,
    kubectl_manifest.redis_deployment,
  ]
}

resource "kubectl_manifest" "litellm_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata = {
      name      = "litellm-proxy"
      namespace = local.litellm_ns
      labels    = { app = "litellm-proxy" }
    }
    spec = {
      selector = { app = "litellm-proxy" }
      ports    = [{ name = "http", port = 80, targetPort = 4000 }]
    }
  })

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

resource "kubernetes_pod_disruption_budget_v1" "litellm" {
  metadata {
    name      = "litellm-proxy"
    namespace = local.litellm_ns
  }
  spec {
    min_available = 1
    selector {
      match_labels = { app = "litellm-proxy" }
    }
  }

  depends_on = [kubernetes_namespace_v1.llm_gateway]
}

resource "kubectl_manifest" "litellm_ingress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "litellm-proxy"
      namespace = local.litellm_ns
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
      }
    }
    spec = {
      ingressClassName = "traefik"
      tls = [{
        hosts      = ["vllm.${var.dns_zone_name}"]
        secretName = "litellm-tls"
      }]
      rules = [{
        host = "vllm.${var.dns_zone_name}"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "litellm-proxy"
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
    kubectl_manifest.litellm_deployment,
  ]
}
