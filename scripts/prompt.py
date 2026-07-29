PROMPTS = [
    """
    Explain how Kubernetes schedules workloads from the moment a Pod is submitted
    to the API server until it starts running on a node. Cover admission controllers,
    etcd persistence, scheduler filtering and scoring, resource requests, node affinity,
    taints and tolerations, topology spread constraints, kubelet behaviour, container
    runtime interaction, CNI networking, CSI storage attachment, and common scheduling
    failures. Include practical troubleshooting examples and commands.
    """,

    """
    Write a comprehensive technical guide to Kubernetes networking. Explain Pod networking,
    Services, ClusterIP, NodePort, LoadBalancer, kube-proxy, iptables, IPVS, DNS resolution,
    ingress controllers, Gateway API, network policies, service meshes, BGP routing, and
    how Cilium uses eBPF. Include packet-flow examples showing how traffic moves from an
    external client to a container.
    """,

    """
    Explain GPU architecture in extreme technical detail. Cover streaming multiprocessors,
    CUDA cores, Tensor Cores, warps, thread blocks, grids, registers, shared memory, L1 and
    L2 cache, global memory, memory coalescing, occupancy, warp divergence, instruction
    scheduling, and how these components affect deep-learning performance.
    """,

    """
    Provide an exhaustive explanation of GPU memory management during LLM inference.
    Cover model weights, activations, attention matrices, KV cache, CUDA contexts,
    temporary buffers, memory fragmentation, PagedAttention, continuous batching,
    quantization, tensor parallelism, and techniques for preventing CUDA out-of-memory
    errors in production.
    """,

    """
    Explain the complete lifecycle of an LLM inference request served by vLLM. Start from
    the incoming OpenAI-compatible API request and cover tokenization, request queuing,
    scheduling, prefill, decoding, continuous batching, PagedAttention, KV-cache block
    allocation, CUDA kernel execution, token sampling, streaming responses, and request
    completion. Include relevant vLLM metrics and bottlenecks.
    """,

    """
    Compare vLLM, Hugging Face TGI, NVIDIA Triton Inference Server, and TensorRT-LLM.
    Discuss architecture, supported models, memory management, dynamic batching,
    continuous batching, tensor parallelism, quantization, observability, deployment
    complexity, GPU utilisation, throughput, latency, and the workloads for which each
    platform is best suited.
    """,

    """
    Write a complete deep dive into distributed PyTorch training using Distributed Data
    Parallel and NCCL. Explain ranks, local ranks, world size, process groups, rendezvous,
    gradient synchronization, AllReduce, DistributedSampler, data parallelism, model
    replication, communication overhead, bucketisation, failure modes, and multi-node
    Kubernetes deployment using Kubeflow Trainer.
    """,

    """
    Explain NCCL communication in multi-GPU and multi-node training. Cover ring AllReduce,
    tree algorithms, NVLink, NVSwitch, PCIe, RDMA, InfiniBand, RoCE, GPUDirect RDMA,
    network-interface selection, topology discovery, collective operations, common NCCL
    environment variables, performance bottlenecks, and troubleshooting NCCL hangs.
    """,

    """
    Design a production-grade Kubernetes platform for hosting GPU-based AI workloads.
    Cover cluster architecture, GPU node pools, NVIDIA GPU Operator, device plugins,
    MIG, time slicing, node labels, taints, topology-aware scheduling, storage, networking,
    observability, autoscaling, workload queues, security, cost optimisation, and disaster
    recovery. Explain the trade-offs behind each design decision.
    """,

    """
    Explain how the NVIDIA GPU Operator works inside Kubernetes. Cover the driver manager,
    container toolkit, device plugin, GPU Feature Discovery, DCGM, DCGM Exporter, MIG
    Manager, validator, node labels, RuntimeClass configuration, driver installation
    strategies, and the interactions between these components when a GPU Pod starts.
    """,

    """
    Write an in-depth guide to monitoring GPU workloads with NVIDIA DCGM Exporter,
    Prometheus, and Grafana. Explain GPU utilisation, SM activity, SM occupancy,
    Tensor Core activity, memory usage, memory bandwidth, PCIe throughput, NVLink traffic,
    power consumption, temperature, throttling, ECC errors, and how to distinguish an
    efficiently utilised GPU from a misleadingly busy GPU.
    """,

    """
    Explain how autoscaling should work for an LLM inference platform on Kubernetes.
    Compare CPU-based scaling with queue-depth, request-rate, latency, KV-cache usage,
    waiting-request, and GPU-utilisation metrics. Cover KEDA, HPA, Prometheus adapters,
    scale-up policies, scale-down stabilisation, cold starts, GPU provisioning delays,
    batching behaviour, and methods for avoiding oscillation.
    """,

    """
    Provide a detailed explanation of transformer architecture. Cover token embeddings,
    positional encoding, self-attention, queries, keys, values, scaled dot-product
    attention, multi-head attention, causal masking, residual connections, layer
    normalization, feed-forward networks, logits, softmax, autoregressive decoding,
    KV caching, and the computational complexity of prefill and decode phases.
    """,

    """
    Explain every major LLM quantization technique, including FP16, BF16, FP8, INT8,
    INT4, GPTQ, AWQ, SmoothQuant, bitsandbytes, and quantization-aware training.
    Discuss memory savings, calibration, accuracy loss, kernel support, hardware
    compatibility, throughput improvements, latency trade-offs, and when each technique
    should be used in production.
    """,

    """
    Design an end-to-end MLOps platform on Kubernetes. Include data ingestion, feature
    engineering, experiment tracking, distributed training, hyperparameter tuning,
    model registry, validation, approval workflows, deployment, canary releases,
    monitoring, drift detection, retraining, lineage, governance, and rollback.
    Explain how tools such as Argo Workflows, MLflow, Kubeflow, KServe, and Prometheus
    could fit into the architecture.
    """,

    """
    Explain how KServe deploys machine-learning models on Kubernetes. Cover InferenceService,
    predictor, transformer, explainer, autoscaling, scale-to-zero, Knative, raw deployment
    mode, ingress, storage initialisation, model formats, runtime selection, canary rollout,
    request routing, observability, and how KServe can be used to deploy a vLLM server.
    """,

    """
    Write a deep technical comparison of data parallelism, tensor parallelism, pipeline
    parallelism, sequence parallelism, context parallelism, and expert parallelism.
    Explain how each strategy partitions computation or model state, its communication
    patterns, memory implications, scalability limits, and how hybrid parallelism is
    applied when training or serving very large language models.
    """,

    """
    Explain how Kubernetes controllers implement reconciliation. Cover desired state,
    observed state, control loops, informers, shared caches, work queues, watches,
    resource versions, optimistic concurrency, finalizers, owner references, garbage
    collection, leader election, idempotency, exponential backoff, and how to design
    a reliable custom operator.
    """,

    """
    Provide an exhaustive explanation of distributed systems. Cover CAP theorem,
    consistency models, consensus, Raft, Paxos, leader election, distributed locks,
    replication, quorum reads and writes, vector clocks, logical clocks, gossip protocols,
    distributed transactions, two-phase commit, saga patterns, event sourcing, CQRS,
    split-brain scenarios, and failure detection.
    """,

    """
    Explain the complete HTTP and HTTPS request lifecycle from a browser to an application
    running in Kubernetes. Cover DNS lookup, ARP, TCP handshake, TLS negotiation,
    certificate validation, HTTP/1.1, HTTP/2, load balancers, reverse proxies, ingress,
    Kubernetes Services, kube-proxy or eBPF routing, Pod networking, application processing,
    response transmission, connection reuse, and common points of failure.
    """,

    """
    Design a highly available multi-region cloud platform for a critical application.
    Cover DNS failover, global load balancing, Kubernetes clusters, databases, replication,
    object storage, caching, queues, secrets, identity, observability, backups, disaster
    recovery, RPO, RTO, deployment strategies, network partition handling, and cost
    trade-offs.
    """,

    """
    Explain how container runtimes work under Kubernetes. Cover containerd, CRI,
    OCI images, image layers, snapshotters, namespaces, cgroups, capabilities, seccomp,
    AppArmor, overlay filesystems, container networking, container lifecycle, shim
    processes, log handling, and the interactions between kubelet and containerd.
    """,

    """
    Write a detailed guide to Linux performance troubleshooting for a heavily loaded
    AI server. Cover CPU saturation, load average, context switches, NUMA locality,
    memory pressure, swapping, page cache, disk latency, network bottlenecks, interrupts,
    GPU-to-CPU transfers, PCIe topology, process inspection, and commands such as top,
    vmstat, iostat, sar, ss, perf, numactl, and nvidia-smi.
    """,

    """
    Explain how production CI/CD should work for Kubernetes-based AI applications.
    Cover source control, testing, container builds, vulnerability scanning, SBOM
    generation, image signing, Helm packaging, GitOps, environment promotion, policy
    enforcement, progressive delivery, rollback, secrets management, model artefact
    versioning, GPU-specific testing, and deployment observability.
    """,
]


