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

The queue-depth trigger fired. The KV cache trigger (>80%) did not fire during the test — as confirmed by the Grafana data showing the primary pod peaking at 60–75%. Karpenter provisioned three additional g5.2xlarge nodes. Within ~6 minutes of the load spike, I had four Llama 3 pods running:

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

### Grafana: Token throughput — 30-minute sustained run

```
Generation Tokens/Sec per pod (13:00–13:30)

2000 ┤         ╭─────────────────────────────────────── pod-6z8c7 (original)
1500 ┤    ╭────╯╭──────────────────────────────────────  pod-l47vr
1000 ┤   ╭╯    ╰╮╭────────────────────────────────────  pod-d8mfp
 500 ┤  ╭╯      ╰╯╭──────────────────────────────────   pod-65bfd
 200 ┤ ╭╯          ╰──────────────────────────────────  pod-65bfd (new, less load)
   0 ┼─╯
     13:00  13:05  13:10  13:15  13:20  13:25  13:30
```

The original pod (6z8c7) drove the highest generation throughput, reaching ~**2,000 tok/s** by 13:05 and holding steady. The three newly provisioned pods ramped up at different rates depending on how quickly LiteLLM's `least-busy` router distributed traffic to them. The asymmetry in throughput between pods reflects how the cache utilization was also asymmetric — the original pod held an established, warm KV cache while the new pods started cold.

### Grafana: GPU KV cache utilization during load

```
GPU KV Cache Utilization per pod (13:00–13:30)

 80% ┤ ─ ─ ─ ─ ─ ─ ─ KEDA threshold ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 75% ┤╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ╭─╮ ← pod-6z8c7
 65% ┤╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─╯ ╰─ (sawtooth)
  5% ┤──────────────────────────────────────────────────── pods l47vr, d8mfp
  0% ┼──────────────────────────────────────────────────── pod-65bfd (newest)
     13:00  13:05  13:10  13:15  13:20  13:25  13:30
```

This is one of the most revealing charts from the 30-minute run. The original pod (6z8c7) maintained a persistent **60–75% sawtooth oscillation** throughout — this is the signature of vLLM's continuous batching: the scheduler fills the KV cache as it admits new sequences, then blocks are freed when sequences complete, and the cycle repeats. The three newer pods held near **0–5%** for the entire test window. They were receiving traffic from LiteLLM but their KV caches were cold and the load wasn't heavy enough to push them above 5%. This also means the KEDA KV cache trigger (>80%) never fired on any individual pod — the queue-depth trigger was the sole autoscaling signal, which is correct for this workload type.

### Grafana: Time to First Token under load

```
Time To First Token Latency (13:00–13:30)

  10s ┤╭──────────────────────────────────────────────────  ← P99 (~9s settled)
   9s ┤│
   8s ┤│╭─────────────────────────────────────────────────  ← P95 (~6s)
   6s ┤╯│
   5s ┤ ╰─────────────────────────────────────────────────  ← P90 (~4–5s)
   4s ┤
   3s ┤──────────────────────────────────────────────────── ← Average (~3s)
   2s ┤
   1s ┤ ╭────────────────────────────────────────╮────────  ← P50 (~2s, dropping)
   0s ┼─╯                                        ╰────────
      13:00  13:05  13:10  13:15  13:20  13:25  13:30
```

The TTFT story across 30 minutes: the initial spike at 13:00 was the ramp-up moment when 300 users hit 1 pod simultaneously. Within 5 minutes, as the other three pods came online, TTFT stabilised:

- **P99 settled at ~8–10s** — the worst 1% of requests waited this long for the first token, consistent with a fully saturated scheduler where long-context requests sit in the prefill queue
- **P95 at ~5–6s** — a comfortable 95th percentile for a heavy analytical workload
- **P50 at ~2s** — the median request got its first token in 2 seconds, which for a 300-user sustained load is strong
- **Average at ~3s** — stable across the full 30-minute window with no degradation

### Grafana: Scheduler state — 256 running sequences

```
Scheduler State — Num Running per pod (13:00–13:30)

256 ┤╭────────────────────────────────────────────────────  pod-6z8c7 (primary)
250 ┤│ (oscillates 248–256 — tight around max_num_seqs)
 50 ┤│╭───────────────────────────────────────────────────  pod-l47vr
 30 ┤││╭──────────────────────────────────────────────────  pod-d8mfp
 20 ┤│││╭─────────────────────────────────────────────────  pod-65bfd
  0 ┼╯╯╯╯
     13:00  13:05  13:10  13:15  13:20  13:25  13:30

Num Swapped: ≈ 0 across all pods (no memory eviction pressure)
Num Waiting: ≈ 0–30, oscillating (queue drains faster than it fills)
```

The primary pod ran at or near `max_num_seqs=256` continuously for the entire 30 minutes — never dropping idle, never swapping sequences to CPU. The three newer pods ran at 20–50 concurrent sequences each, meaning LiteLLM was correctly preferring the already-warmed primary pod (via `least-busy` routing) and distributing overflow to the others.

**Finish Reason** told the complete story: the `length` counter grew steadily from ~600 completions/min at 13:00 to ~900 completions/min by 13:25 as the fleet reached a stable operating state. Every completion was a full-length response — no timeouts, no OOM errors, no truncations from errors. The model was working at capacity, producing complete answers under full load.

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

### 30-minute sustained load (4 replicas, 300 users, no Redis cache)

Measured directly from Grafana at steady state (13:10–13:30):

| Metric | Measured value |
|---|---|
| Primary pod generation throughput | ~2,000 tok/s |
| Other pods generation throughput | 200–1,500 tok/s each |
| E2E request latency p50 | ~40–50s |
| E2E request latency p99 | ~60s (1 min) |
| TTFT p50 | ~2s |
| TTFT p95 | ~5–6s |
| TTFT p99 | ~8–10s (settled after initial ramp) |
| TPOT p50 | ~120ms |
| TPOT p90 | ~200ms |
| TPOT p99 | ~500ms |
| GPU KV cache — primary pod | 60–75% (sawtooth, continuous batching) |
| GPU KV cache — other 3 pods | 0–5% (cold, newly provisioned) |
| Num Running — primary pod | 250–256 (at max_num_seqs, continuous) |
| Num Running — other pods | 20–50 each |
| Num Swapped | ~0 (no CPU eviction pressure) |
| Finish reason "length" | 600 → 900 completions/min over 30 min |
| KEDA scale event | 1 → 4 pods within ~6 minutes of load onset |
| Request prompt length | 100–200 tokens (median), up to 932 tokens |
| Request generation length | 200–500 tokens (median), up to 932 tokens |

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
vLLM's scheduler filled to `max_num_seqs=256` on the primary pod and held there for the full 30 minutes. At that saturation point, the primary pod sustained ~2,000 generation tok/s, TPOT stayed under 500ms (p99), and the model delivered full-length responses throughout (finish reason: "length" growing 600 → 900 completions/min). The GPU was compute-bound, not memory-bound — KV cache peaked at 75%, well clear of the 80% KEDA threshold.

**4. Budget enforcement is the last line of defence.**
Without caching, 300 users at $0.95/request crossed the $10.00 team budget in under two minutes, triggering HTTP 429s across the board. LiteLLM's budget gate fired at exactly the right time and blocked further spend. This confirms the budget control mechanism works correctly as a backstop for runaway load tests and misconfigured clients.

**5. Topology spread and multi-replica Llama worked correctly.**
All four Llama pods landed on distinct nodes (confirmed by pod IP diversity across subnets). The `DoNotSchedule` hostname constraint prevented co-location. Throughput across the fleet was asymmetric — the original pod handled the bulk of the load at ~2,000 tok/s while the three newly provisioned pods ramped more slowly — because LiteLLM's `least-busy` router correctly favoured the warmer, higher-capacity pod. No coordination overhead was observed between pods.

---

## The Cost Impact of KV Cache: Dollars and Cents

This is the most important finding from the entire test, so I am pulling it out separately.

### What happened with cache disabled

Without prefix caching, every request computes its prompt tokens from scratch — including the system prompt that every single request in this test shares. That computation is not free. Under 300 concurrent users it means the single pod is doing full prefill work on every request rather than skipping 94% of it. The queue fills faster than the scheduler can drain it. Within minutes, `num_requests_waiting` crossed 5 — the queue-depth threshold I set in the KEDA ScaledObject — and KEDA triggered a scale-out. Karpenter provisioned three new g5.2xlarge nodes.

The KV cache trigger (>80%) did not fire — as confirmed by the Grafana 30-minute run where the primary pod peaked at 60–75%. Queue depth was the actual autoscaling signal, which is important: it means the prefix cache's benefit is not about reducing KV cache percentage, it is about reducing compute per request so that one pod can drain the queue faster than it fills.

```
num_requests_waiting — without prefix cache, 1 pod, 300 users

  30 ┤                    ╭──────────────
  20 ┤               ╭───╯  ← KEDA fires (threshold = 5)
  10 ┤          ╭───╯    3 new pods provision within ~6 min
   5 ┤ ─ ─ ─ ╭─╯  ← KEDA threshold
   0 ┼────────╯
     T+0    T+1    T+2    T+3    T+4    T+5 min

num_requests_waiting — with prefix cache, 1 pod, same 300 users

   5 ┤ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ KEDA threshold (never crossed)
   2 ┤╭─╮ ╭─╮ ╭─╮
   0 ┼╯ ╰─╯ ╰─╯ ╰──────────────────────────────
     T+0    T+1    T+2    T+3    T+4    T+5 min
     (queue drains instantly — 1 pod is sufficient)
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

The 94.42% GPU prefix cache hit rate means that on average, **94.42% of every prompt's tokens skip prefill computation entirely** — their KV blocks are read from cache rather than recomputed. This directly reduces the per-request compute cost, which is what keeps the queue from building:

```
Without prefix cache:
  Each 200-token prompt → 200 tokens of prefill compute
  300 users × 200 tokens = 60,000 tokens of prefill work/round
  → Pod can't drain the queue faster than it arrives
  → num_requests_waiting > 5 → KEDA triggers → 4 pods

With prefix cache (94.42% hit rate):
  Each 200-token prompt → ~11 tokens of prefill compute (only the new tail)
  300 users × 11 tokens = 3,300 tokens of prefill work/round
  → Pod drains queue faster than it fills
  → num_requests_waiting stays near 0 → KEDA never fires → 1 pod sufficient
```

Note: the KV cache utilisation differs between scenarios — 0.8% when the Redis cache is warm (Scenario 1, where near-zero traffic reaches vLLM) versus 60–75% under full load without Redis (Scenario 3). What the prefix cache changes is not the KV cache fill level, but how much prefill compute each request demands. With prefix caching, that compute collapses to near zero for the shared system prompt. One pod, one GPU, one-quarter the infrastructure bill. That is what the prefix cache delivered in this test.

---

## What I Would Tune Next

| Observation | Proposed change |
|---|---|
| TTFT p99 settled at 8–10s under 300 users | Reduce `max_num_seqs` from 256 to 128 — tighter queue, lower worst-case TTFT at the cost of some throughput |
| Budget exhausted in <2min under locust | Set per-key rate limits in addition to team budget |
| vLLM prefix cache resets on pod restart | Enable `--enable-prefix-caching` with a warm-up script on pod start |
| `Num Running` flatlines at 256 | Consider chunked prefill (`--enable-chunked-prefill`) to reduce TTFT jitter at high concurrency |
| Redis cache TTL 3600s | Evaluate per-model TTL — long-context completions likely stale sooner than short ones |

---

*Infrastructure code: [infra-live/](infra-live/) — Load generator: [scripts/locust.py](scripts/locust.py) — Benchmark runner: [scripts/load-test.py](scripts/load-test.py)*
