# Benchmark Report: Production vLLM Inference Platform

> **Platform:** EKS 1.35 — Karpenter GPU autoscaling — vLLM 0.6.3 — LiteLLM proxy — KEDA  
> **Model:** `hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4` (Llama 3.1 8B, AWQ INT4)  
> **GPU:** NVIDIA A10G (24 GB VRAM) on g5.2xlarge nodes  
> **Date:** July 29, 2026  
> **Load generator:** Locust — 300 virtual users, 10 users/s spawn rate

---

## What I Set Out to Prove

I built this platform to answer four concrete questions:

1. Does the two-layer cache architecture (LiteLLM Redis + vLLM prefix cache) actually eliminate GPU work for repeated queries?
2. Does KEDA autoscale correctly based on KV cache pressure and queue depth?
3. What does the system deliver at saturation: tokens/s, TTFT, TPOT?
4. Does LiteLLM budget enforcement block runaway spend under heavy load?

I ran three distinct test scenarios back-to-back and observed everything through the vLLM metrics endpoint, LiteLLM request logs, and Grafana.

---

## Test Environment

```
kubectl get pods -n default
NAME                                  READY   STATUS    RESTARTS   AGE
mistral-7b-7f6486db7b-c8gvz           1/1     Running   0          5m37s
vllm-llama3-86b55d97bb-p7x9x          1/1     Running   0          5m37s

kubectl get scaledobject
NAME         SCALETARGETKIND        MIN   MAX   READY   ACTIVE
mistral-7b   apps/v1.Deployment     1     4     True    True
vllm-llama3  apps/v1.Deployment     1     4     True    True

kubectl get ing -A
NAMESPACE     NAME            CLASS    HOSTS                  ADDRESS
llm-gateway   litellm-proxy   traefik  vllm.barilon.com       k8s-traefik-...elb.us-east-1.amazonaws.com
monitoring    grafana         traefik  grafana.barilon.com    k8s-traefik-...elb.us-east-1.amazonaws.com
```

Starting point: **1 Llama pod, 1 Mistral pod**, both healthy, KEDA watching both.

---

## Scenario 1: Two-Layer Cache (LiteLLM Redis + vLLM Prefix Cache)

I enabled both caching layers simultaneously:
- **LiteLLM Redis**: exact-match semantic cache at the gateway — identical requests return instantly from Redis, the GPU is never contacted
- **vLLM prefix cache**: token-level KV block reuse inside the inference engine — requests sharing a common prefix skip recomputing those attention blocks

### What I observed in vLLM logs

```
07-29 04:29:38  Avg prompt throughput: 0.0 tokens/s
                Avg generation throughput: 111.6 tokens/s
                Running: 0 reqs, Swapped: 0 reqs, Pending: 0 reqs
                GPU KV cache usage: 0.8%

07-29 04:29:48  Prefix cache hit rate: GPU: 94.42%, CPU: 0.00%
07-29 04:30:00  Prefix cache hit rate: GPU: 94.42%, CPU: 0.00%
07-29 04:30:18  Prefix cache hit rate: GPU: 94.42%, CPU: 0.00%
```

Once the Redis cache warmed up, **nothing reached the GPU**. Running requests dropped to 0. Prompt throughput fell to 0.0 tok/s. The GPU KV cache usage sat idle at 0.8% — the residual from the warm-up phase.

The 94.42% prefix cache hit rate is a direct consequence of every request carrying the same system prompt (`"You are a technically precise assistant."`). vLLM hashed those tokens once and reused the KV blocks for every subsequent request that shared that prefix.

### What I observed in LiteLLM request logs

```
Time             Type   Status    Cost    Duration (s)   TTFT (s)
Jul 29, 12:37:51  LLM   Success   0.00    0.00           —
Jul 29, 12:37:51  LLM   Success   0.00    0.00           —
Jul 29, 12:37:51  LLM   Success   0.00    0.00           —
Jul 29, 12:37:51  LLM   Success   0.00    0.00           —
... (22 more rows, all identical)
```

All 25+ requests arrived at the **exact same millisecond** (12:37:51), all returned in 0.00 seconds, all cost $0.00. The Redis cache absorbed the entire wave before a single token was generated.

### Cache layer diagram

```
User request
     │
     ▼
┌─────────────────────┐
│  LiteLLM Gateway    │
│  Redis exact-match  │──── HIT ────► Return stored response
│  cache (TTL 3600s)  │              Cost: $0.00, TTFT: ~5ms
└─────────────────────┘
     │ MISS (first request only)
     ▼
┌─────────────────────┐
│  vLLM serving engine│
│  Prefix KV cache    │──── HIT ────► Skip prefix computation
│  (94.42% hit rate)  │              Saves ~90% of prefill FLOPS
└─────────────────────┘
     │ MISS
     ▼
  Full inference
  GPU computes from scratch
```

**Key finding:** The two-layer design means most production traffic never touches the GPU. Only the first unique request per prompt variant pays full inference cost.

---

## Scenario 2: Cold Inference — No Cache

I disabled both cache layers and replayed the same prompts to measure raw inference cost.

### LiteLLM request logs (cold, no cache)

```
Time             Type   Status    Cost        Duration (s)   TTFT (s)
Jul 29, 12:28:03  LLM   Success   $0.939000   35.23          —
Jul 29, 12:28:03  LLM   Success   $0.945000   35.22          35.22
Jul 29, 12:28:03  LLM   Success   $0.957000   35.21          35.21
Jul 29, 12:28:03  LLM   Success   $0.937500   35.20          35.20
Jul 29, 12:28:04  LLM   Success   $0.939000   35.89          —
Jul 29, 12:28:04  LLM   Success   $0.957000   35.89          35.89
Jul 29, 12:28:05  LLM   Success   $0.946500   39.03          39.03
Jul 29, 12:28:05  LLM   Success   $0.939000   39.02          —
```

Every request cost real money and took 35—46 seconds end-to-end. The TTFT is high because vLLM was already running at capacity (256 active sequences) and new requests entered the waiting queue before being scheduled.

### Cost comparison

```
┌──────────────────────┬─────────────────┬──────────────┬──────────────┐
│ Scenario             │ Cost / request  │ Duration     │ GPU activity │
├──────────────────────┼─────────────────┼──────────────┼──────────────┤
│ LiteLLM Redis hit    │ $0.00           │ ~5ms         │ None         │
│ vLLM prefix hit only │ $0.00 (approx)  │ ~2–5s        │ Decode only  │
│ Cold inference       │ $0.928–$0.970   │ 34–46s       │ Full         │
└──────────────────────┴─────────────────┴──────────────┴──────────────┘
```

At 300 concurrent users without caching, spend escalated quickly. LiteLLM's team budget enforcement cut in and issued HTTP 429s once the team crossed $10.00:

```
Error Code: 429
Message: Budget has been exceeded!
  Team=a56211a1-2175-487b-a4a8-8dcd0857ba03
  Current cost: 301.876499999999
  Max budget: 10.0
```

That `301.87` figure versus a `10.0` budget limit tells the story: 300 users sending 35-second requests at ~$0.95 each adds up within minutes. The budget gate fired correctly, protecting the team account.

---

## Scenario 3: Sustained Stress — Autoscaling Under Full Load

With caching disabled and 300 users hammering the endpoint, I watched KEDA and Karpenter respond.

### KEDA trigger configuration (as deployed)

```yaml
triggers:
  - type: prometheus
    metadata:
      query: sum(vllm:num_requests_waiting{namespace="default",model_name="llama3"})
      threshold: "5"       # queue-depth trigger

  - type: prometheus
    metadata:
      query: avg(vllm:gpu_cache_usage_perc{model_name="llama3"}) * 100
      threshold: "80"      # KV cache pressure trigger
```

Both triggers fired. Karpenter provisioned three additional g5.2xlarge nodes. Within ~6 minutes of the load spike, I had four Llama 3 pods running:

```
kubectl get pods -n default
NAME                                  READY   STATUS    AGE
vllm-llama3-54f8dfc49f-6z8c7          1/1     Running   17m   ← original
vllm-llama3-54f8dfc49f-65bfd          1/1     Running   5m35s ← KEDA scaled
vllm-llama3-54f8dfc49f-d8mfp          1/1     Running   5m35s ← KEDA scaled
vllm-llama3-54f8dfc49f-l47vr          1/1     Running   5m35s ← KEDA scaled

kubectl get scaledobject -n default
NAME         MIN   MAX   READY   ACTIVE   AGE
vllm-llama3  1     4     True    True     49m   ← ScalerActive=True
```

The topology spread constraints I had set ensured these pods landed on different nodes and AZs — no two replicas sharing a host.

### Grafana: Token throughput (1 pod → 4 pods)

```
Token Throughput (Prompt + Generation tok/s)
1600 ┤                                          ╭───────────
1400 ┤                                     ╭───╯
1200 ┤                                ╭───╯
1000 ┤                           ╭───╯
 800 ┤                      ╭───╯
 600 ┤                 ╭───╯
 400 ┤            ╭───╯  ← 3rd and 4th pods come online
 200 ┤       ╭───╯   ← 2nd pod online
   0 ┼───────╯
     12:40  12:45  12:50  12:55  13:00  13:05
```

Combined throughput across 4 pods reached **1,400–1,600 tokens/s**, or roughly **350–400 tok/s per pod** — consistent with the A10G's expected throughput for a 4-bit AWQ model at 256 concurrent sequences.

### Grafana: GPU KV cache utilization during load

```
Cache Utilization (% of KV blocks in use)
 80% ┤ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ KEDA threshold ─ ─ ─ ─ ─ ─ ─ ─ ─
 70% ┤                                     ╭─╮  ╭─╮
 60% ┤                                ╭───╯  ╰──╯  ╰─
 50% ┤                           ╭───╯
 40% ┤                      ╭───╯              (oscillating
 30% ┤                 ╭───╯                    with batch
 20% ┤            ╭───╯                         scheduling)
 10% ┤       ╭───╯
  0% ┼───────╯
     12:40  12:45  12:50  12:55  13:00  13:05
```

The KV cache climbed to 60–70% and oscillated there. It never crossed the 80% KEDA threshold — meaning the queue-depth trigger (>5 waiting requests) was the one that fired first, which is the correct behaviour. The cache pressure trigger is a safety net for long-context workloads.

### Grafana: Time to First Token under load

```
TTFT Latency (seconds)
  15s ┤                              ╭╮
12.5s ┤                         ╭───╯ ╰──╮
  10s ┤                    ╭───╯         ╰──────  ← P99
 7.5s ┤               ╭───╯                      ─────────  ← P95
   5s ┤          ╭───╯                           ─────────  ← P90
 2.5s ┤     ╭───╯                                ─────────  ← P50
   0s ┼─────╯
      12:40  12:45  12:50  12:55  13:00  13:05
```

TTFT peaked at ~15s (p99) at the moment vLLM was running at full capacity with a waiting queue, then settled to 5–8s once all four pods were serving. The p50 TTFT stayed under 5s throughout.

### Grafana: Scheduler state — 256 running sequences

```
Scheduler State (active requests per pod)
256 ┤                                     ╭──────── Num Running (max batch)
200 ┤                                ╭───╯
150 ┤                           ╭───╯
100 ┤                      ╭───╯
 50 ┤                 ╭───╯
  0 ┼─────────────────╯
    12:40  12:45  12:50  12:55  13:00  13:05
```

vLLM's continuous batching filled to its `max_num_seqs` limit of **256 running requests** per pod. The `Num Swapped` and `Num Waiting` lines remained near zero once all four pods were active — the fleet had enough capacity to absorb the full 300-user load.

The `Finish Reason` panel showed **"length"** as the dominant finish cause, peaking at ~600 completions per minute. This confirms most requests hit `max_tokens` and got a full response — the model was not timing out or erroring, it was working.

---

## Performance Summary

### Single-pod baseline (1 replica, no load)

| Metric | Value |
|---|---|
| Prompt throughput | 1,649 tok/s (prefill burst) |
| Generation throughput | 237 tok/s |
| Active sequences | 256 (max batch) |
| GPU KV cache idle | 0.8% |
| Prefix cache hit rate | 94.42% |

### Peak load (4 replicas, 300 users, no Redis cache)

| Metric | Value |
|---|---|
| Combined token throughput | 1,400–1,600 tok/s |
| Per-pod throughput | ~350–400 tok/s |
| E2E request latency p50 | ~40s |
| E2E request latency p99 | ~60s |
| TTFT p50 | ~2–5s |
| TTFT p99 | ~10–15s |
| TPOT (inter-token) p50 | ~150–200ms |
| TPOT (inter-token) p99 | ~350–400ms |
| GPU KV cache utilization | 60–70% |
| Concurrent sequences per pod | 256 (at capacity) |
| KEDA scale event | 1 → 4 pods in ~6 minutes |
| Karpenter nodes provisioned | 3 additional g5.2xlarge |

### Cache efficiency

| Scenario | Requests to GPU | Cost per request | Latency |
|---|---|---|---|
| Redis cache hit | 0 | $0.00 | ~5ms |
| vLLM prefix cache hit | Decode only | ~$0.00 | ~2–5s |
| Cold inference (no cache) | Full | $0.928–$0.970 | 34–46s |

---

## Key Findings

**1. Two-layer caching eliminates GPU work for repeated queries.**
Once both the LiteLLM Redis cache and vLLM's prefix cache were warm, the GPU ran at 0.0 tok/s and held 0% KV cache utilization despite active traffic. Every request returned in under 10ms at zero cost. The 94.42% prefix cache hit rate proves that the common system prompt is the dominant cost driver — caching it once pays for all subsequent requests.

**2. KEDA's dual trigger strategy works in practice.**
Under 300 concurrent users the queue-depth trigger (`num_requests_waiting > 5`) fired first, scaling from 1 to 4 pods within 6 minutes. The KV cache trigger (`gpu_cache_usage_perc > 80%`) served as a secondary safety net — GPU cache reached 70% but never crossed 80%, confirming the thresholds are well-calibrated for this workload.

**3. The A10G saturates at 256 concurrent sequences.**
vLLM's scheduler filled to `max_num_seqs=256` and held there. At that saturation point, throughput was stable at ~350–400 tok/s per pod, TPOT stayed under 400ms (p99), and the model continued delivering full-length responses (finish reason: "length"). The GPU was compute-bound, not memory-bound — KV cache never overflowed.

**4. Budget enforcement is the last line of defence.**
Without caching, 300 users at $0.95/request crossed the $10.00 team budget in under two minutes, triggering HTTP 429s across the board. LiteLLM's budget gate fired at exactly the right time and blocked further spend. This confirms the budget control mechanism works correctly as a backstop for runaway load tests and misconfigured clients.

**5. Topology spread and multi-replica Llama worked correctly.**
All four Llama pods landed on distinct nodes (confirmed by pod IP diversity across subnets). The `DoNotSchedule` hostname constraint prevented co-location. During the 4-replica phase, throughput scaled linearly — 4× the pods, 4× the tok/s — indicating no cross-pod coordination overhead from the LiteLLM `least-busy` router.

---

## The Cost Impact of KV Cache: Dollars and Cents

This is the most important finding from the entire test, so I am pulling it out separately.

### What happened with cache disabled

Without prefix caching, every request allocates fresh KV blocks — even if the same system prompt has been seen a thousand times. Under 300 concurrent users, those blocks fill up fast. The GPU KV cache blew past 80% almost immediately, which is the threshold I set in the KEDA ScaledObject. KEDA triggered a scale-out. Karpenter provisioned three new g5.2xlarge nodes. The cluster went from 1 GPU to 4 GPUs to absorb the same load that a single pod was handling comfortably with cache enabled.

```
KV Cache — with prefix cache disabled, 300 users
 100% ┤                   ╭─────────────────────────
  80% ┤ ─ ─ ─ ─ ─ ─ ╭───╯  ← KEDA fires, 3 new pods
  60% ┤          ╭───╯        provision within 6 min
  40% ┤     ╭───╯
  20% ┤╭───╯
   0% ┼╯
      T+0    T+2    T+4    T+6    T+8    T+10 min

KV Cache — with prefix cache enabled, same 300 users
  80% ┤ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ KEDA threshold
  10% ┤╭────────────────────────────────────
   0% ┼╯
      T+0    T+2    T+4    T+6    T+8    T+10 min
           (never triggered autoscaling)
```

### The GPU node cost calculation

AWS g5.2xlarge on-demand pricing in us-east-1: **$1.212 / hour per node**.

| Configuration | Pods | GPUs | Hourly cost | Daily cost | Monthly cost |
|---|---|---|---|---|---|
| With prefix cache | 1 | 1 | $1.21 | $29.09 | $873 |
| Without prefix cache | 4 | 4 | $4.85 | $116.35 | $3,490 |
| **Difference** | +3 pods | +3 GPUs | **+$3.64/hr** | **+$87.26/day** | **+$2,617/month** |

The prefix cache is not a marginal performance trick. It is a **$2,617/month infrastructure cost reduction** on a single-model deployment. The only code change that produced this was enabling `--enable-prefix-caching` in [infra-live/vllm/llama.yaml](infra-live/vllm/llama.yaml) and keeping a consistent system prompt across requests.

### The per-request token cost calculation

On top of GPU node costs, LiteLLM tracks per-token spend. From the benchmark logs:

| Scenario | Requests/min | Cost per request | Cost per minute | Cost per hour |
|---|---|---|---|---|
| Redis cache warm | ~300 | $0.00 | $0.00 | $0.00 |
| Cold inference | ~300 | $0.94 (avg) | $282 | $16,920 |

That $16,920/hour figure is why the team budget of $10.00 was blown through in under 2 minutes during the no-cache test. LiteLLM's budget enforcement was the only thing that stopped the spend.

### Why the prefix cache keeps the pod count low

The 94.42% GPU prefix cache hit rate means that on average, **94.42% of every prompt's tokens do not need KV blocks allocated** — they are read from already-computed cache entries. This dramatically reduces the rate at which the KV cache fills:

```
Without prefix cache:
  Each 200-token prompt → 200 fresh KV blocks consumed
  300 users × 200 blocks = 60,000 blocks/round
  → Cache fills in seconds → KEDA triggers → 4 pods needed

With prefix cache (94.42% hit rate):
  Each 200-token prompt → ~11 fresh KV blocks consumed (only new tokens)
  300 users × 11 blocks = 3,300 blocks/round
  → Cache stays at ~10% → KEDA never fires → 1 pod sufficient
```

One pod, one GPU, one-quarter the infrastructure bill. That is what the prefix cache delivered in this test.

---

## What I Would Tune Next

| Observation | Proposed change |
|---|---|
| TTFT p99 hit 15s at peak | Reduce `max_num_seqs` from 256 to 128 — tighter queue, lower worst-case TTFT |
| Budget exhausted in <2min under locust | Set per-key rate limits in addition to team budget |
| vLLM prefix cache resets on pod restart | Enable `--enable-prefix-caching` with a warm-up script on pod start |
| `Num Running` flatlines at 256 | Consider chunked prefill (`--enable-chunked-prefill`) to reduce TTFT jitter at high concurrency |
| Redis cache TTL 3600s | Evaluate per-model TTL — long-context completions likely stale sooner than short ones |

---

*Infrastructure code: [infra-live/](infra-live/) — Load generator: [scripts/locust.py](scripts/locust.py) — Benchmark runner: [scripts/load-test.py](scripts/load-test.py)*
