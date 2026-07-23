# LLM Inference Platform on EKS — Production-Grade Multi-Model Serving

A fully Terraform-managed platform for serving multiple large language models at scale on AWS. This project provisions an Amazon EKS cluster with GPU autoscaling via Karpenter, serves Meta Llama 3.1 8B and Mistral 7B through [vLLM](https://github.com/vllm-project/vllm), and fronts them with a [LiteLLM](https://github.com/BerriAI/litellm) proxy gateway for unified routing, cost tracking, rate limiting, and caching — all exposed over HTTPS via Traefik and cert-manager.

---

## Architecture

```
                                    Internet
                                       │
                              vllm.barilon.com
                                       │
                              ┌────────▼────────┐
                              │   AWS NLB        │
                              │  (Traefik)       │
                              └────────┬────────┘
                                       │ HTTPS (TLS via cert-manager + Let's Encrypt)
                              ┌────────▼────────┐
                              │    Traefik       │
                              │ Ingress Controller│
                              └────────┬────────┘
                                       │
                              ┌────────▼────────────────────────────┐
                              │        LiteLLM Proxy (2 replicas)    │
                              │          namespace: llm-gateway       │
                              │                                       │
                              │  • Unified OpenAI-compatible API      │
                              │  • Rate limiting per API key          │
                              │  • Per-token cost tracking            │
                              │  • Redis response caching             │
                              │  • Request logging to PostgreSQL      │
                              │  • Model routing & fallback           │
                              └──────┬──────────────┬───────────────┘
                                     │              │
                   ┌─────────────────▼──┐    ┌──────▼──────────────────┐
                   │  vLLM — Llama 3.1  │    │  vLLM — Mistral 7B      │
                   │  8B Instruct        │    │  Instruct v0.3          │
                   │  namespace: default │    │  namespace: default     │
                   │  2 replicas         │    │  1 replica              │
                   │  port :80           │    │  port :8000             │
                   │  g5/g6 GPU nodes    │    │  g5/g6 GPU nodes        │
                   │  EFS cache (RWX)    │    │  EFS cache (RWX)        │
                   └────────────────────┘    └─────────────────────────┘

Supporting services (managed node group — t3.medium):
  Karpenter · GPU Operator · KEDA · Prometheus · Grafana · cert-manager
  EBS CSI · EFS CSI · AWS Load Balancer Controller

Autoscaling:
  KEDA → vllm:num_requests_waiting > 5 → scale Llama replicas (2–4)
  KEDA → vllm:num_requests_waiting > 5 → scale Mistral replicas (1–2)
  Karpenter → unschedulable GPU pod → provision g5/g6 EC2 in ~90s
```

---

## What This Project Demonstrates

| Capability | Implementation |
|---|---|
| **LLM API gateway** | LiteLLM proxy with unified OpenAI-compatible routing across multiple models |
| **Multi-model serving** | Llama 3.1 8B + Mistral 7B running on separate GPU nodes behind one endpoint |
| **GPU autoscaling** | Karpenter NodePool targeting g5/g6 families; provisions in ~90 seconds |
| **Request-driven scaling** | KEDA ScaledObjects per model on `vllm:num_requests_waiting` Prometheus metric |
| **Shared model cache** | Amazon EFS (ReadWriteMany) — weights downloaded once, shared across all replicas |
| **Cost tracking** | LiteLLM logs every token to PostgreSQL with per-model pricing metadata |
| **Response caching** | Redis cache in LiteLLM reduces duplicate GPU computation |
| **TLS everywhere** | cert-manager issues Let's Encrypt certs via Route53 DNS-01; Traefik terminates |
| **Pod Identity** | EKS Pod Identity for all CSI drivers — no node-level IRSA or IMDS access |
| **Observability** | Prometheus + Grafana + DCGM GPU exporter + per-model ServiceMonitors |
| **Two-phase IaC** | Makefile targets decouple cluster bootstrap from workload deployment |
| **High availability** | PodDisruptionBudgets on all workloads; multi-AZ across 5 availability zones |

---

## Technology Stack

| Layer | Technology | Version |
|---|---|---|
| Infrastructure | Terraform | ~1.15 |
| Cloud | AWS (EKS, EFS, EBS, IAM, VPC, Route53, NLB) | Provider 6.42 |
| Kubernetes | Amazon EKS | 1.35 |
| GPU Autoscaling | Karpenter | 1.6.0 |
| LLM Gateway | LiteLLM Proxy | latest |
| LLM Serving | vLLM (OpenAI-compatible) | 0.6.3 |
| Models | Llama 3.1 8B Instruct · Mistral 7B Instruct v0.3 | — |
| GPU Runtime | NVIDIA GPU Operator | v26.3.1 |
| Event-driven Scaling | KEDA | 2.16.1 |
| Ingress | Traefik | 34.5.0 |
| TLS | cert-manager + Let's Encrypt (DNS-01/Route53) | 1.18.2 |
| Metrics | kube-prometheus-stack | 70.4.2 |
| Dashboards | Grafana | (bundled) |
| Gateway Database | PostgreSQL 16 | — |
| Gateway Cache | Redis 7 | — |
| Model Storage | Amazon EFS (encrypted, ReadWriteMany) | — |
| Block Storage | Amazon EBS gp3 (encrypted) | — |

---

## Project Structure

```
barilon/
├── README.md
├── scripts/
│   └── load-test.py               # vLLM load testing script
│
├── module/                        # Reusable Terraform modules
│   ├── networking/                # VPC, subnets, NAT gateway, route tables
│   └── eks/                       # EKS cluster, node groups, IAM, addons
│
└── infra-live/                    # Production root module
    ├── Makefile                   # Deployment commands
    ├── providers.tf               # AWS, Kubernetes, Helm, kubectl providers
    ├── variables.tf               # All input variable declarations
    ├── terraform.tfvars.example   # Variable template (never commit real values)
    ├── outputs.tf
    │
    ├── main.tf                    # VPC + EKS + Karpenter module calls
    ├── karpenter.tf               # Karpenter Helm + NodePool/NodeClass manifests
    ├── gpu-operator.tf            # NVIDIA GPU Operator (driver.enabled=false, AL2023)
    ├── ebs.tf                     # EBS CSI driver, Pod Identity, gp3 StorageClass
    ├── efs.tf                     # EFS filesystem, mount targets, CSI driver, StorageClass
    ├── vllm.tf                    # Llama 3.1 8B — Deployment, Service, PVC, PDB, Secret
    ├── mistral.tf                 # Mistral 7B — Deployment, Service, PVC, ServiceMonitor, ScaledObject
    ├── litellm.tf                 # LiteLLM gateway — Proxy, Redis, PostgreSQL, Ingress
    ├── monitoring.tf              # Prometheus stack, Grafana, vLLM ServiceMonitor
    ├── keda.tf                    # KEDA Helm + Llama ScaledObject
    ├── cert-manager.tf            # cert-manager, ClusterIssuers, Route53 IAM
    ├── ingress.tf                 # AWS Load Balancer Controller + Traefik
    │
    ├── karpenter/
    │   ├── values.yaml.tpl
    │   ├── nodepool-default.yaml  # General-purpose NodePool (c/m/r families)
    │   ├── nodepool-gpu.yaml      # GPU NodePool (g5/g6, on-demand, tainted)
    │   ├── nodeclass-default.yaml.tpl
    │   └── nodeclass-gpu.yaml.tpl # AL2023 AMI, 100 GiB gp3 root disk
    │
    └── vllm/
        └── deployment.yaml        # Llama 3.1 8B Deployment manifest
```

---

## LiteLLM Gateway

LiteLLM sits between all clients and the vLLM inference backends. Every request goes through the proxy regardless of which model is targeted — clients never talk directly to a vLLM pod.

### Why a Gateway?

**Unified API surface**

Both models (Llama and Mistral) are exposed through a single endpoint (`vllm.barilon.com`) with a single OpenAI-compatible API. Clients switch models by changing the `model` field in the request body — no endpoint change required.

```bash
# Target Llama 3.1
curl https://vllm.barilon.com/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{"model": "llama3", "messages": [{"role": "user", "content": "Hello"}]}'

# Target Mistral — same endpoint, same client code
curl https://vllm.barilon.com/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -d '{"model": "mistral-7b", "messages": [{"role": "user", "content": "Hello"}]}'
```

**Rate limiting**

LiteLLM enforces per-key rate limits (requests per minute, tokens per minute) configured in the master key or virtual key settings. This prevents a single client from saturating a GPU and starving other users — something vLLM alone cannot do.

**Cost tracking**

Every request is logged to PostgreSQL with token counts and per-model pricing. The `model_info` block in the config assigns a cost per input/output token:

```yaml
model_info:
  input_cost_per_token:  0.00000015   # $0.15 per 1M input tokens
  output_cost_per_token: 0.00000030   # $0.30 per 1M output tokens
```

This produces a spend dashboard per API key, per model, and per time window — essential for chargeback or cost-aware routing in multi-tenant setups.

**Response caching (Redis)**

Identical prompts (same model + same messages) are served from Redis instead of hitting the GPU. The cache TTL is 3600 seconds. For use cases with repeated or templated prompts (batch classification, document summarisation pipelines), this can cut GPU time by 30–70%.

**Model fallback**

If a vLLM backend is unavailable, LiteLLM can be configured to fall back to another model or return a graceful error — rather than surfacing a raw 502 to the client.

**Future extensibility**

Adding a third model (e.g., a code model) requires one block in the LiteLLM config and a new vLLM Deployment — no changes to DNS, TLS, or client code.

### Gateway Architecture

```
Client → LiteLLM Proxy
              │
              ├── Redis (check cache) ──► cache hit → return immediately
              │
              ├── Route by model name
              │     ├── "llama3"    → http://vllm-llama3.default:80/v1
              │     └── "mistral-7b"→ http://mistral-7b.default:8000/v1
              │
              └── Log request + tokens + cost → PostgreSQL
```

---

## How It Works

### 1. Cluster Foundation

A 2-node managed node group (`t3.medium`) runs all system components: Karpenter, KEDA, GPU Operator, Prometheus, Traefik, cert-manager, and the LiteLLM stack. These nodes are provisioned first and never serve inference traffic.

### 2. GPU Node Provisioning (Karpenter)

The `gpu-inference` NodePool targets `g5` and `g6` instance families across 5 AZs. Nodes carry a `nvidia.com/gpu=true:NoSchedule` taint — only GPU-requesting pods land on them. Karpenter provisions a node within ~90 seconds of a pending GPU pod and consolidates idle nodes after 10 minutes.

```yaml
requirements:
  - key: karpenter.k8s.aws/instance-family
    operator: In
    values: ["g5", "g6"]        # A10G (g5) and L4 (g6) GPUs
taints:
  - key: nvidia.com/gpu
    effect: NoSchedule
```

### 3. LLM Inference Backends (vLLM)

**Llama 3.1 8B** — 2 replicas, 1 GPU each, served on port 80 in the `default` namespace.
- `--dtype bfloat16` — native A10G/L4 precision
- `--gpu-memory-utilization 0.85` — 15% VRAM headroom for burst traffic
- `--max-model-len 4096` — conservative context preserves VRAM for concurrency

**Mistral 7B Instruct v0.3** — 1 replica, 1 GPU, served on port 8000 in the `default` namespace.
- `--quantization fp8` — reduces VRAM footprint by ~50% with minimal quality loss
- `--tokenizer-mode mistral` — required for correct Mistral tokenisation
- `--dtype auto` — lets vLLM select optimal dtype for fp8 quantised weights

Both models download weights to their own EFS Access Point on first start. Subsequent restarts or new replicas read from cache — eliminating the 10–15 minute cold start after the first run.

### 4. Request-Driven Autoscaling (KEDA)

Each model has its own `ScaledObject`. KEDA polls Prometheus every 30 seconds and scales the respective Deployment independently.

| Model | Metric query | Threshold | Min | Max |
|---|---|---|---|---|
| Llama 3.1 8B | `sum(vllm:num_requests_waiting{model_name="llama3"})` | 5 | 2 | 4 |
| Mistral 7B | `sum(vllm:num_requests_waiting{model_name="mistral-7b"})` | 5 | 1 | 2 |

A GPU cache pressure trigger (`vllm:gpu_cache_usage_perc > 80%`) acts as a secondary scale signal for both models. Scale-down cooldown is 300 seconds.

### 5. TLS and Ingress

Traefik runs as the ingress controller with an internet-facing NLB provisioned by the AWS Load Balancer Controller. cert-manager issues Let's Encrypt certificates via Route53 DNS-01 challenge — no HTTP-01 port exposure required.

```
vllm.barilon.com  → NLB → Traefik → LiteLLM proxy (llm-gateway ns)
grafana.barilon.com → NLB → Traefik → Grafana (monitoring ns)
```

### 6. Observability

- **Prometheus** scrapes both vLLM backends via `ServiceMonitor` resources (one per model)
- **DCGM Exporter** (GPU Operator) exposes per-GPU utilisation, memory, and temperature
- **Grafana** at `grafana.barilon.com` — dashboards for application and GPU-level metrics
- **LiteLLM spend dashboard** — built-in UI at `/ui` showing cost per model and API key
- **Prometheus retention**: 15 days on a 50 GiB gp3 EBS volume

---

## Prerequisites

- AWS CLI configured with a named profile
- Terraform ≥ 1.15
- `kubectl` and `helm` installed locally
- A [Hugging Face](https://huggingface.co/) account with access to both models
- Route53 hosted zone for your domain
- S3 bucket for Terraform remote state (`amz-state-lock` in `us-east-1`)

---

## Deployment

This project uses a **two-phase apply** pattern — the Kubernetes providers need a live cluster endpoint, so the cluster must exist before workloads are planned.

### Phase 1 — Cluster Foundation

```bash
cd infra-live
make apply-cluster
```

After Phase 1, update kubeconfig and restart CSI drivers to pick up Pod Identity credentials:

```bash
aws eks update-kubeconfig --name barilon --region us-east-1 --profile <your-profile>
kubectl rollout restart deployment/ebs-csi-controller -n kube-system
kubectl rollout restart deployment/efs-csi-controller -n kube-system
```

### Phase 2 — Workloads

```bash
make apply-workloads
```

Watch model downloads (first run: Llama ~16 GB, Mistral ~14 GB through NAT GW — one-time cost ~$1.35, then served from EFS cache):

```bash
kubectl get pods -w
kubectl logs -f deployment/vllm-llama3
kubectl logs -f deployment/mistral-7b
```

### Clean Teardown

Scale down GPU workloads first so Karpenter deprovisions the expensive nodes, then remove the NLB before destroying the VPC:

```bash
kubectl scale deployment vllm-llama3 mistral-7b --replicas=0 -n default
kubectl delete nodeclaim --all
helm uninstall traefik -n traefik   # removes the NLB
cd infra-live && make destroy
```

### Day-2 Operations

```bash
make plan        # Fast plan (no state refresh) — for iterating on config
make plan-full   # Full refresh plan — use before production changes
make apply       # Apply a previously saved plan file
make destroy     # Tear down all resources
```

---

## Configuration Reference

| Variable | Description |
|---|---|
| `region` | AWS region |
| `profile` | AWS CLI profile |
| `cluster_name` | EKS cluster name |
| `eks_version` | Kubernetes version |
| `dns_zone_name` | Route53 hosted zone (e.g. `barilon.com`) |
| `acme_email` | Email for Let's Encrypt registration |
| `hf_token` | Hugging Face API token (sensitive) |
| `grafana_password` | Grafana admin password (sensitive) |
| `litellm_master_key` | LiteLLM master API key (sensitive) |
| `litellm_pg_password` | PostgreSQL password for LiteLLM (sensitive) |
| `admin_user_arn` | IAM user ARN with cluster-admin access |

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in values. Never commit `terraform.tfvars` — it is gitignored.

---

## Networking Design

| Subnet type | CIDRs | Purpose |
|---|---|---|
| Public | 10.0.1–2–3–7–8.0/24 | NLB, NAT Gateway |
| Private | 10.0.4–5–6–9–10.0/24 | EKS nodes (all workloads) |

- 5 AZs (us-east-1a/b/c/d/f) — us-east-1e excluded (no GPU capacity)
- Single NAT Gateway (cost-optimised; add per-AZ for full HA)
- EFS mount targets in every private subnet for AZ-local NFS throughput
- EFS security group allows TCP 2049 from VPC CIDR only

---

## IAM and Security

- **EKS Pod Identity** for EBS CSI, EFS CSI, cert-manager, and AWS Load Balancer Controller — no node-level IRSA, no IMDS access from pods
- **Least privilege**: each component carries only the minimum managed or inline policy required
- **EFS encrypted at rest**; EBS gp3 volumes with `encrypted=true`
- **EKS API auth mode** with access entry scoped to the admin IAM user only
- **AL2023 GPU AMI** — NVIDIA drivers pre-baked; `driver.enabled=false` in GPU Operator avoids reinstallation
- **LiteLLM master key** enforces authentication on every API request; no unauthenticated access to inference endpoints

---

## Observability

### vLLM Metrics (per model)

| Metric | What it tells you |
|---|---|
| `vllm:num_requests_waiting` | Queue depth — primary KEDA autoscaling trigger |
| `vllm:gpu_cache_usage_perc` | KV cache pressure — secondary scale trigger at >80% |
| `vllm:num_requests_running` | Active GPU slots in use |
| `vllm:e2e_request_latency_seconds` | End-to-end latency histogram |
| `vllm:tokens_per_second` | Inference throughput |

### GPU Metrics (DCGM)

| Metric | What it tells you |
|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | Compute utilisation % |
| `DCGM_FI_DEV_FB_USED` | VRAM used (bytes) |
| `DCGM_FI_DEV_GPU_TEMP` | Temperature °C |

---

## Known Limitations

- **Single NAT Gateway** — all AZs share one NAT GW. Add per-AZ gateways for full HA.
- **Plaintext secrets in tfvars** — move `hf_token`, `litellm_master_key`, and `litellm_pg_password` to AWS Secrets Manager before sharing this configuration with a team.
- **No NetworkPolicy** — pods communicate freely within the cluster. Add Calico or VPC CNI policies to restrict blast radius between namespaces.
- **Single GPU per replica** — each vLLM pod requests one GPU. For 70B+ models, switch `--distributed-executor-backend` to `ray` and request multiple GPUs per pod.
- **PostgreSQL single replica** — the LiteLLM database is a single StatefulSet pod. For production HA, replace with Amazon RDS.

---

## Cost Profile (approximate)

| Resource | Type | Est. monthly |
|---|---|---|
| EKS control plane | Managed | ~$73 |
| System nodes (2× t3.medium) | On-demand | ~$60 |
| Llama GPU nodes (2× g5.2xlarge) | On-demand | ~$1,100 |
| Mistral GPU node (1× g6.2xlarge) | On-demand | ~$400 |
| EFS (2× 100 GiB volumes) | Standard | ~$60 |
| EBS — Prometheus (50 GiB gp3) | gp3 | ~$5 |
| EBS — PostgreSQL (10 GiB gp3) | gp3 | ~$1 |
| NAT Gateway | Per GB | ~$35+ |
| Route53 + ACM | Hosted zone + cert | ~$1 |

Karpenter consolidates idle GPU nodes after 10 minutes — off-peak hours cost only the system node group (~$133/month). Model weights are cached on EFS so the one-time NAT GW download cost (~$1.35 per model) is never repeated.
