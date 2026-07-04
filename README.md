# vLLM on EKS — Production-Grade LLM Inference Infrastructure

A fully Terraform-managed platform for serving large language models at scale on AWS. This project provisions an Amazon EKS cluster with GPU autoscaling via Karpenter, deploys Meta's Llama 3.1 8B Instruct through [vLLM](https://github.com/vllm-project/vllm), and wraps it with request-driven autoscaling (KEDA), a shared model cache (EFS), and a full observability stack (Prometheus + Grafana + DCGM GPU metrics).

---

## Architecture

```
                          ┌─────────────────────────────────────────────────────┐
                          │                   AWS VPC (10.0.0.0/16)             │
                          │                                                     │
                          │  ┌─────────────┐         ┌─────────────────────┐   │
                          │  │ Public      │         │ Private Subnets     │   │
  Internet ──────────────►│  │ Subnets     │         │ us-east-1a/b/c/d/f  │   │
                          │  │ (NAT GW)    │         │                     │   │
                          │  └─────────────┘         │  ┌───────────────┐  │   │
                          │                          │  │  EKS Control  │  │   │
                          │                          │  │  Plane        │  │   │
                          │                          │  └───────┬───────┘  │   │
                          │                          │          │           │   │
                          │                          │  ┌───────▼───────┐  │   │
                          │                          │  │ Managed Node  │  │   │
                          │                          │  │ Group (2x     │  │   │
                          │                          │  │ t3.medium)    │  │   │
                          │                          │  │               │  │   │
                          │                          │  │ • Karpenter   │  │   │
                          │                          │  │ • GPU Operator│  │   │
                          │                          │  │ • KEDA        │  │   │
                          │                          │  │ • Prometheus  │  │   │
                          │                          │  └───────────────┘  │   │
                          │                          │                     │   │
                          │                          │  ┌───────────────┐  │   │
                          │                          │  │ GPU Nodes     │  │   │
                          │                          │  │ (Karpenter)   │  │   │
                          │                          │  │               │  │   │
                          │                          │  │ g5.2xlarge    │  │   │
                          │                          │  │ (NVIDIA A10G) │  │   │
                          │                          │  │ g6.2xlarge    │  │   │
                          │                          │  │ (NVIDIA L4)   │  │   │
                          │                          │  │               │  │   │
                          │                          │  │ ┌───────────┐ │  │   │
                          │                          │  │ │ vLLM Pod  │ │  │   │
                          │                          │  │ │ (replica) │ │  │   │
                          │                          │  │ └─────┬─────┘ │  │   │
                          │                          │  └───────┼───────┘  │   │
                          │                          │          │           │   │
                          │                          │  ┌───────▼───────┐  │   │
                          │                          │  │  EFS Volume   │  │   │
                          │                          │  │  (100 GiB     │  │   │
                          │                          │  │  ReadWriteMany│  │   │
                          │                          │  │  model cache) │  │   │
                          │                          │  └───────────────┘  │   │
                          │                          └─────────────────────┘   │
                          └─────────────────────────────────────────────────────┘

Autoscaling signal: KEDA polls Prometheus metric vllm:num_requests_waiting
→ threshold=5 → scale GPU node count 2–4 → Karpenter provisions EC2 on demand
```

---

## What This Project Demonstrates

| Capability | Implementation |
|---|---|
| **GPU autoscaling** | Karpenter NodePool targeting g5/g6 instance families; provisions in ~2 min |
| **LLM inference** | vLLM v0.6.3 serving Llama 3.1 8B Instruct with OpenAI-compatible API |
| **Request-driven HPA** | KEDA ScaledObject on custom Prometheus metric (`vllm:num_requests_waiting`) |
| **Shared model cache** | Amazon EFS (ReadWriteMany) so all replicas share one downloaded model |
| **Pod Identity** | AWS EKS Pod Identity for CSI drivers — no node-level IRSA or IMDS access |
| **Observability** | kube-prometheus-stack + DCGM GPU exporter + vLLM ServiceMonitor |
| **Two-phase IaC** | Makefile targets decouple cluster bootstrap from workload deployment |
| **High availability** | 2 replicas across AZs, PodDisruptionBudget (minAvailable=1) |

---

## Technology Stack

| Layer | Technology | Version |
|---|---|---|
| Infrastructure | Terraform | ~1.15 |
| Cloud | AWS (EKS, EFS, EBS, IAM, VPC) | Provider 6.42 |
| Kubernetes | Amazon EKS | 1.35 |
| GPU Autoscaling | Karpenter | 1.6.0 |
| LLM Serving | vLLM (OpenAI-compatible) | 0.6.3 |
| Model | Meta Llama 3.1 8B Instruct | — |
| GPU Runtime | NVIDIA GPU Operator | v26.3.1 |
| Event-driven Scaling | KEDA | 2.16.1 |
| Metrics | kube-prometheus-stack | 70.4.2 |
| Dashboards | Grafana | (bundled) |
| Model Storage | Amazon EFS (gp, encrypted) | — |
| Block Storage | Amazon EBS gp3 (encrypted) | — |

---

## Project Structure

```
barilon/
├── README.md
│
├── module/                        # Reusable Terraform modules
│   ├── networking/                # VPC, subnets, NAT gateway, route tables
│   │   ├── main.tf
│   │   ├── variable.tf
│   │   └── output.tf
│   └── eks/                       # EKS cluster, node groups, IAM, addons
│       ├── main.tf
│       ├── variable.tf
│       └── output.tf
│
└── infra-live/                    # Production root module
    ├── Makefile                   # Deployment commands (see Deployment section)
    ├── providers.tf               # AWS, Kubernetes, Helm, kubectl providers
    ├── variables.tf               # All input variable declarations
    ├── terraform.tfvars           # Environment values (do NOT commit secrets)
    ├── outputs.tf                 # VPC ID, subnet IDs
    │
    ├── main.tf                    # VPC + EKS + Karpenter module calls
    ├── karpenter.tf               # Karpenter Helm release + NodePool/NodeClass manifests
    ├── gpu-operator.tf            # NVIDIA GPU Operator (driver.enabled=false for AL2023)
    ├── ebs.tf                     # EBS CSI driver, Pod Identity, gp3 StorageClass
    ├── efs.tf                     # EFS filesystem, mount targets, CSI driver, StorageClass
    ├── vllm.tf                    # vLLM Deployment, Service, PVC, PDB, HF token Secret
    ├── monitoring.tf              # Prometheus stack + vLLM ServiceMonitor
    ├── keda.tf                    # KEDA Helm release + ScaledObject
    │
    ├── karpenter/                 # Karpenter manifest templates
    │   ├── values.yaml.tpl        # Helm values (cluster endpoint, queue name)
    │   ├── nodepool-default.yaml  # General-purpose NodePool (c/m/r families)
    │   ├── nodepool-gpu.yaml      # GPU NodePool (g5/g6, on-demand, tainted)
    │   ├── nodeclass-default.yaml.tpl
    │   └── nodeclass-gpu.yaml.tpl # AL2023 AMI, 100 GiB gp3 root disk
    │
    └── vllm/
        └── deployment.yaml        # vLLM Kubernetes Deployment manifest
```

---

## How It Works

### 1. Cluster Foundation

A 2-node managed node group (`t3.medium`) runs the system components: Karpenter, KEDA, GPU Operator, and Prometheus. These nodes are provisioned first and do not serve inference traffic.

### 2. GPU Node Provisioning (Karpenter)

The `gpu-inference` NodePool targets `g5` and `g6` instance families across 5 AZs (us-east-1a/b/c/d/f). Nodes carry a `nvidia.com/gpu=true:NoSchedule` taint so only GPU-requesting pods land on them. Karpenter provisions a node within ~90 seconds of a pod becoming unschedulable and consolidates idle nodes after 10 minutes.

```yaml
# nodepool-gpu.yaml (excerpt)
requirements:
  - key: karpenter.k8s.aws/instance-family
    operator: In
    values: ["g5", "g6"]        # A10G and L4 GPUs
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["on-demand"]
taints:
  - key: nvidia.com/gpu
    effect: NoSchedule
```

### 3. LLM Inference (vLLM)

vLLM runs 2 replicas, each requesting one GPU. The model (`meta-llama/Llama-3.1-8B-Instruct`) is downloaded once to the shared EFS volume and reused across replicas and restarts — eliminating the ~15-minute cold-start on every pod launch.

Key configuration decisions:
- `--dtype bfloat16` — native precision for A10G/L4, maximises throughput
- `--gpu-memory-utilization 0.85` — 15% headroom prevents OOM on burst traffic
- `--max-model-len 4096` — conservative context window preserves VRAM for concurrency
- `--distributed-executor-backend mp` — multiprocessing backend for single-GPU replicas

### 4. Request-Driven Autoscaling (KEDA)

KEDA watches the Prometheus metric `vllm:num_requests_waiting` — the number of requests queued inside vLLM waiting for a GPU slot. When this exceeds 5, KEDA scales the Deployment up (max 4 replicas), and Karpenter provisions the additional GPU nodes. When the queue drains, KEDA scales down after a 300-second cooldown.

```
User requests → vLLM queue grows → Prometheus scrapes metric
→ KEDA fires → Deployment scaled up → Karpenter provisions GPU node
→ New vLLM pod scheduled → Queue drains → Cooldown → Scale down
```

### 5. Model Cache (Amazon EFS)

A 100 GiB EFS filesystem with `ReadWriteMany` access allows all vLLM replicas to share one cached copy of the model weights. The EFS CSI driver uses EKS Pod Identity (not node-level IRSA) to call the EFS API for access point creation.

### 6. Observability

- **Prometheus** scrapes vLLM's `/metrics` endpoint via a `ServiceMonitor`
- **DCGM Exporter** (bundled in GPU Operator) exposes per-GPU utilisation, memory, and temperature
- **Grafana** provides dashboards for both application and GPU-level metrics
- **Prometheus retention**: 15 days on a 50 GiB gp3 EBS volume

---

## Prerequisites

- AWS CLI configured with a named profile
- Terraform ≥ 1.15
- `kubectl` and `helm` installed locally
- A [Hugging Face](https://huggingface.co/) account with access to `meta-llama/Llama-3.1-8B-Instruct`
- S3 bucket for Terraform remote state (`amz-state-lock` in `us-east-1`)

---

## Deployment

This project uses a **two-phase apply** pattern. The Kubernetes providers need a live cluster endpoint to initialise, so the cluster must exist before workloads can be planned.

### Phase 1 — Cluster Foundation

Provisions VPC, EKS cluster, managed node group, CSI drivers, and their IAM roles. Nothing Kubernetes-native yet.

```bash
cd infra-live
make apply-cluster
```

This is equivalent to:
```bash
terraform apply -auto-approve \
  -target=module.vpc \
  -target=module.eks \
  -target=module.karpenter \
  -target=aws_iam_role.ebs_csi_driver \
  -target=aws_iam_role_policy_attachment.ebs_csi_driver \
  -target=aws_eks_addon.ebs_csi_driver \
  -target=aws_eks_pod_identity_association.ebs_csi_driver \
  -target=aws_iam_role.efs_csi_driver \
  -target=aws_iam_role_policy_attachment.efs_csi_driver \
  -target=aws_eks_addon.efs_csi_driver \
  -target=aws_eks_pod_identity_association.efs_csi_driver
```

After Phase 1, update your kubeconfig:
```bash
aws eks update-kubeconfig --name barilon --region us-east-1 --profile <your-profile>
```

Restart CSI driver pods so they pick up Pod Identity credentials (only needed on first deploy):
```bash
kubectl rollout restart deployment/ebs-csi-controller -n kube-system
kubectl rollout restart deployment/efs-csi-controller -n kube-system
```

### Phase 2 — Workloads

Deploys everything else: Karpenter NodePools, GPU Operator, KEDA, Prometheus, EFS StorageClass, and the vLLM Deployment.

```bash
make apply-workloads
```

Watch the vLLM pods come up (model download takes 5–15 minutes on first run):
```bash
kubectl get pods -w
kubectl logs -f deployment/vllm-llama3
```

### Day-2 Operations

```bash
make plan            # Fast plan (no state refresh) — for iterating on config
make plan-full       # Full refresh plan — use before production changes
make apply           # Apply a previously saved plan file
make destroy         # Tear down all resources (no state refresh)
```

---

## Configuration Reference

All values live in `infra-live/terraform.tfvars`. Sensitive values (`hf_token`, `grafana_password`) should be supplied via environment variables or a secrets manager in a real environment — never committed to source control.

| Variable | Description | Example |
|---|---|---|
| `region` | AWS region | `us-east-1` |
| `profile` | AWS CLI profile | `barilon` |
| `vpc_cidr` | VPC CIDR block | `10.0.0.0/16` |
| `azs` | Availability zones (exclude us-east-1e) | `["us-east-1a", ...]` |
| `cluster_name` | EKS cluster name | `barilon` |
| `eks_version` | Kubernetes version | `1.35` |
| `node_groups` | Managed node group definitions | see tfvars |
| `hf_token` | Hugging Face API token | `hf_...` |
| `grafana_password` | Grafana admin password | — |
| `admin_user_arn` | IAM user with cluster-admin access | `arn:aws:iam::...` |

---

## Networking Design

| Subnet type | CIDRs | Purpose |
|---|---|---|
| Public | 10.0.1–2–3–7–8.0/24 | NAT Gateway, load balancers |
| Private | 10.0.4–5–6–9–10.0/24 | EKS nodes (all workloads) |

- Single NAT Gateway (cost-optimised; replace with per-AZ NAT for full HA)
- EFS mount targets in every private subnet for AZ-local NFS access
- Security group on EFS allows TCP 2049 from VPC CIDR only

---

## IAM & Security

- **EKS Pod Identity** used for both EBS and EFS CSI drivers — no instance-level IRSA, no IMDS access from pods
- **Least privilege**: each driver role carries only its managed policy (`AmazonEBSCSIDriverPolicy`, `AmazonEFSCSIDriverPolicy`)
- **EFS encrypted at rest**; EBS gp3 volumes created with `encrypted=true`
- **EKS API authentication mode** (`authentication_mode = "API"`) with access entry for the admin IAM user
- **AL2023 AMI** on GPU nodes — NVIDIA drivers are pre-baked, so `driver.enabled=false` in GPU Operator avoids redundant driver reinstallation

---

## Observability Details

### vLLM Metrics

vLLM exposes a Prometheus-compatible `/metrics` endpoint. Key metrics:

| Metric | What it tells you |
|---|---|
| `vllm:num_requests_waiting` | Requests queued, waiting for a free GPU slot (KEDA trigger) |
| `vllm:gpu_cache_usage_perc` | KV cache utilisation — high values indicate memory pressure |
| `vllm:num_requests_running` | Actively being processed |
| `vllm:e2e_request_latency_seconds` | End-to-end latency histogram |

### GPU Metrics (DCGM)

| Metric | What it tells you |
|---|---|
| `DCGM_FI_DEV_GPU_UTIL` | GPU compute utilisation % |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | GPU memory bandwidth utilisation % |
| `DCGM_FI_DEV_FB_USED` | GPU framebuffer memory used (bytes) |
| `DCGM_FI_DEV_GPU_TEMP` | GPU temperature °C |

---

## Known Limitations

- **Single NAT Gateway** — all private subnets route through one NAT GW in us-east-1a. A NAT failure takes down outbound traffic for all AZs. Add per-AZ NAT gateways for production HA.
- **Plaintext secrets in tfvars** — `hf_token` and `grafana_password` must be moved to AWS Secrets Manager or passed via `TF_VAR_` environment variables before this is used in a shared team environment.
- **No NetworkPolicy** — pods can communicate freely within the cluster. Add Calico or VPC CNI network policies to restrict blast radius.
- **Single GPU per replica** — the `--distributed-executor-backend mp` flag and `nvidia.com/gpu: 1` limit each replica to one GPU. For models requiring multi-GPU (70B+), switch to `ray` backend and adjust resource requests.

---

## Cost Profile (approximate)

| Resource | Type | Est. monthly |
|---|---|---|
| EKS control plane | Managed | ~$73 |
| System nodes (2× t3.medium) | On-demand | ~$60 |
| GPU node (1× g5.2xlarge) | On-demand | ~$550 |
| GPU node (1× g6.2xlarge) | On-demand | ~$400 |
| EFS (100 GiB) | Standard | ~$30 |
| EBS (50 GiB Prometheus) | gp3 | ~$5 |
| NAT Gateway | Per GB | ~$35+ |

Karpenter consolidates idle GPU nodes after 10 minutes of underutilisation, which significantly reduces GPU costs during off-peak hours.
