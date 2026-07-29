#!/usr/bin/env python3
"""
Stress benchmark for the vLLM inference platform.

Metrics measured:
  TTFT        Time to First Token (p50 / p99) via streaming
  TPOT        Time Per Output Token (inter-token latency)
  E2E         End-to-end latency at p50 / p90 / p99
  Throughput  req/s and tok/s at each concurrency level
  GPU cache   KV-cache fill % sampled during live load
  KEDA        Queue depth ramp — exact concurrency where scale-out fires

Stages:
  baseline    10 sequential requests — clean p50/p99 with no contention
  ttft        TTFT via streaming at 1, 10, 30, 50 concurrent
  stress      Concurrency ramp 10 → 25 → 50 → 100, then 2-min sustained hold
  keda        Ramp slow long requests until num_requests_waiting > threshold
  cache       Same-prompt cache speedup
  all         Run every stage in order

Usage:
  export LITELLM_URL=https://vllm.barilon.com
  export LITELLM_MASTER_KEY=sk-...
  export VLLM_METRICS_URL=http://localhost:8000    # kubectl port-forward svc/vllm-llama3 8000:80

  python scripts/load-test.py --model llama3
  python scripts/load-test.py --model llama3 --stage stress
  python scripts/load-test.py --model mistral-7b  --stage all
"""

import warnings
warnings.filterwarnings("ignore")

import argparse, concurrent.futures, json, math, os, statistics, sys, time
from datetime import datetime

import requests
from openai import OpenAI

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LITELLM_URL   = os.environ.get("LITELLM_URL",        "https://vllm.barilon.com")
API_KEY       = os.environ.get("LITELLM_MASTER_KEY",  "")
VLLM_METRICS  = os.environ.get("VLLM_METRICS_URL",   "")
OUTPUT_DIR    = "outputs"
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Prompt bank — short (fast) and long (KV-cache pressure)
SHORT = [
    "What is PagedAttention? Answer in one sentence.",
    "What is quantization in one sentence?",
    "What is continuous batching?",
    "Why is LLM inference memory-bound?",
    "What is a KV cache?",
    "Define throughput in LLM serving.",
    "What is AWQ quantization?",
    "What is fp8 precision?",
    "What is KEDA?",
    "What is Karpenter?",
]

LONG = [
    (
        "You are a senior ML infrastructure engineer. "
        "Write a detailed technical comparison between vLLM and Hugging Face TGI "
        "covering memory management, batching strategies, quantization support, "
        "latency characteristics, and production readiness. "
        "Include concrete numbers where possible and give a final recommendation."
    ),
    (
        "Explain in depth how transformer self-attention works from first principles. "
        "Cover the query, key, and value projections, scaled dot-product attention, "
        "multi-head attention, and how Grouped Query Attention reduces memory usage. "
        "Then explain how PagedAttention builds on this to improve GPU utilization."
    ),
    (
        "You are designing a production LLM serving platform on Kubernetes. "
        "Describe the full architecture including the inference backend, API gateway, "
        "autoscaling strategy, observability stack, and cost optimization approach. "
        "Justify every technology choice and explain the tradeoffs you considered."
    ),
    (
        "Explain the relationship between GPU memory, KV cache size, and concurrent "
        "request capacity in vLLM. Walk through the calculation for a 7B parameter "
        "model with GQA running on a 24 GB GPU at fp8 precision, showing how many "
        "concurrent requests fit at 4096-token context length."
    ),
    (
        "Compare AWQ and GPTQ quantization methods for large language models. "
        "Explain how each method works, their accuracy-efficiency tradeoffs, "
        "hardware requirements, and which scenarios each is best suited for. "
        "Include discussion of activation-aware calibration and how it differs "
        "from weight-only post-training quantization."
    ),
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def wait_for_server(url: str):
    print(f"Connecting to {url} ...")
    for i in range(60):
        try:
            r = requests.get(f"{url}/v1/models",
                             headers={"Authorization": f"Bearer {API_KEY}"},
                             timeout=5, verify=False)
            if r.status_code == 200:
                models = [m["id"] for m in r.json().get("data", [])]
                print(f"  Ready. Models: {models}\n")
                return
        except Exception:
            pass
        time.sleep(5)
        if i % 6 == 5:
            print(f"  Still waiting ({(i+1)*5}s) ...")
    raise RuntimeError("Server unreachable after 5 minutes.")


def vllm_metrics() -> dict:
    if not VLLM_METRICS:
        return {}
    try:
        r = requests.get(f"{VLLM_METRICS}/metrics", timeout=3)
        out = {}
        for line in r.text.splitlines():
            if line.startswith("#") or not line.strip():
                continue
            name = line.split("{")[0].split()[0]
            try:
                out[name] = float(line.split()[-1])
            except (ValueError, IndexError):
                pass
        return out
    except Exception:
        return {}


def pct(data: list, p: float) -> float:
    if not data:
        return 0.0
    s = sorted(data)
    return s[max(0, int(math.ceil(p / 100 * len(s))) - 1)]


def header(title: str):
    print(f"\n{'─' * 62}")
    print(f"  {title}")
    print(f"{'─' * 62}")


def table(cols: list, rows: list):
    w = [max(len(str(c)), max((len(str(r[i])) for r in rows), default=0))
         for i, c in enumerate(cols)]
    fmt = "  " + "  ".join(f"{{:<{x}}}" for x in w)
    print(fmt.format(*cols))
    print("  " + "  ".join("─" * x for x in w))
    for row in rows:
        print(fmt.format(*row))


# ---------------------------------------------------------------------------
# Request functions
# ---------------------------------------------------------------------------

def req_blocking(client, model, prompt, max_tokens=200):
    """Non-streaming request — returns latency + token stats."""
    t0 = time.perf_counter()
    resp = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        max_tokens=max_tokens,
        temperature=0.7,
    )
    lat = time.perf_counter() - t0
    ctok = resp.usage.completion_tokens
    return {"latency": lat, "completion_tokens": ctok,
            "tok_per_s": ctok / lat if lat > 0 else 0}


def req_streaming(client, model, prompt, max_tokens=200):
    """Streaming request — measures TTFT and inter-token latency."""
    t0      = time.perf_counter()
    ttft    = None
    tok_ts  = []

    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        max_tokens=max_tokens,
        temperature=0.7,
        stream=True,
    )
    for chunk in stream:
        content = chunk.choices[0].delta.content
        if content:
            now = time.perf_counter()
            if ttft is None:
                ttft = now - t0
            tok_ts.append(now)

    e2e    = time.perf_counter() - t0
    n_tok  = len(tok_ts)
    if n_tok > 1:
        gaps   = [tok_ts[i] - tok_ts[i-1] for i in range(1, n_tok)]
        tpot   = statistics.mean(gaps) * 1000   # ms
    else:
        tpot   = 0.0

    return {
        "ttft":             ttft or e2e,
        "e2e":              e2e,
        "tpot_ms":          round(tpot, 2),
        "completion_tokens": n_tok,
        "tok_per_s":         n_tok / e2e if e2e > 0 else 0,
    }


# ---------------------------------------------------------------------------
# Stage: baseline
# ---------------------------------------------------------------------------

def stage_baseline(client, model, n=10):
    header(f"BASELINE — {n} sequential requests, short prompts")
    results = []
    for i in range(n):
        prompt = SHORT[i % len(SHORT)]
        r = req_blocking(client, model, prompt, max_tokens=120)
        results.append(r)
        print(f"  [{i+1:2d}/{n}]  {r['latency']:.2f}s  "
              f"{r['completion_tokens']} tok  {r['tok_per_s']:.1f} tok/s")

    lats = [r["latency"] for r in results]
    toks = [r["tok_per_s"] for r in results]
    out  = {
        "p50_s": round(pct(lats, 50), 3),
        "p99_s": round(pct(lats, 99), 3),
        "mean_tok_per_s": round(statistics.mean(toks), 1),
    }
    print(f"\n  p50={out['p50_s']}s  p99={out['p99_s']}s  "
          f"tok/s={out['mean_tok_per_s']}")
    return out


# ---------------------------------------------------------------------------
# Stage: TTFT (streaming)
# ---------------------------------------------------------------------------

def stage_ttft(client, model):
    levels = [1, 10, 30, 50]
    header(f"TTFT (streaming) — concurrency levels {levels}")
    rows, summary = [], []

    for c in levels:
        prompts = (LONG * 10)[:c]
        results = []

        with concurrent.futures.ThreadPoolExecutor(max_workers=c) as pool:
            futs = [pool.submit(req_streaming, client, model, p, 250)
                    for p in prompts]
            for f in concurrent.futures.as_completed(futs):
                results.append(f.result())

        ttfts = [r["ttft"] for r in results]
        e2es  = [r["e2e"]  for r in results]
        tpots = [r["tpot_ms"] for r in results]
        toks  = [r["tok_per_s"] for r in results]

        row = {
            "concurrency":   c,
            "ttft_p50_ms":   round(pct(ttfts, 50) * 1000),
            "ttft_p99_ms":   round(pct(ttfts, 99) * 1000),
            "tpot_p50_ms":   round(pct(tpots, 50)),
            "e2e_p50_s":     round(pct(e2es, 50), 2),
            "e2e_p99_s":     round(pct(e2es, 99), 2),
            "mean_tok_per_s": round(statistics.mean(toks), 1),
        }
        summary.append(row)
        rows.append([c,
                     f"{row['ttft_p50_ms']}ms",
                     f"{row['ttft_p99_ms']}ms",
                     f"{row['tpot_p50_ms']}ms",
                     f"{row['e2e_p50_s']}s",
                     f"{row['e2e_p99_s']}s",
                     row["mean_tok_per_s"]])

    table(["concur", "TTFT p50", "TTFT p99", "TPOT p50",
           "E2E p50", "E2E p99", "tok/s"], rows)
    return summary


# ---------------------------------------------------------------------------
# Stage: stress ramp + sustained hold
# ---------------------------------------------------------------------------

def _snapshot(label: str, met: dict):
    running = met.get("vllm:num_requests_running", 0)
    waiting = met.get("vllm:num_requests_waiting", 0)
    cache   = met.get("vllm:gpu_cache_usage_perc", 0)
    print(f"  {label:<22}  running={int(running):3d}  "
          f"waiting={int(waiting):3d}  gpu_cache={cache*100:5.1f}%")
    return {"running": int(running), "waiting": int(waiting),
            "gpu_cache_pct": round(cache * 100, 1)}


def stage_stress(client, model):
    levels    = [10, 25, 50, 100]
    hold_secs = 120
    header(f"STRESS — ramp {levels}, then {hold_secs}s sustained at 50")

    ramp_rows, ramp_data = [], []
    for c in levels:
        prompts = (LONG * 20)[:c]
        lats, toks = [], []
        t0 = time.perf_counter()

        with concurrent.futures.ThreadPoolExecutor(max_workers=c) as pool:
            futs = [pool.submit(req_blocking, client, model, p, 300)
                    for p in prompts]
            # sample metrics mid-flight
            time.sleep(2)
            snap = _snapshot(f"c={c} (in-flight)", vllm_metrics())
            for f in concurrent.futures.as_completed(futs):
                r = f.result()
                lats.append(r["latency"])
                toks.append(r["completion_tokens"])

        elapsed = time.perf_counter() - t0
        total_t = sum(toks)
        row = {
            "concurrency": c,
            "req_per_s":   round(c / elapsed, 2),
            "tok_per_s":   round(total_t / elapsed, 1),
            "p50_s":       round(pct(lats, 50), 2),
            "p90_s":       round(pct(lats, 90), 2),
            "p99_s":       round(pct(lats, 99), 2),
            "gpu_cache":   snap["gpu_cache_pct"],
            "waiting":     snap["waiting"],
        }
        ramp_data.append(row)
        ramp_rows.append([c, row["req_per_s"], row["tok_per_s"],
                          f"{row['p50_s']}s", f"{row['p90_s']}s",
                          f"{row['p99_s']}s",
                          f"{row['gpu_cache']}%", row["waiting"]])

    table(["concur", "req/s", "tok/s", "p50", "p90", "p99",
           "gpu_cache", "waiting"], ramp_rows)

    # Sustained hold at c=50
    header(f"SUSTAINED — c=50 for {hold_secs}s (sampled every 15s)")
    sustained_samples = []
    deadline = time.time() + hold_secs

    def _worker():
        while time.time() < deadline:
            p = LONG[int(time.time()) % len(LONG)]
            try:
                req_blocking(client, model, p, 300)
            except Exception:
                pass

    with concurrent.futures.ThreadPoolExecutor(max_workers=50) as pool:
        futs = [pool.submit(_worker) for _ in range(50)]
        sample_t = time.time() + 15
        while time.time() < deadline:
            if time.time() >= sample_t:
                m    = vllm_metrics()
                snap = _snapshot(
                    f"t={int(time.time() - (deadline - hold_secs))}s",
                    m)
                sustained_samples.append(snap)
                sample_t += 15
            time.sleep(1)

    return {"ramp": ramp_data, "sustained": sustained_samples}


# ---------------------------------------------------------------------------
# Stage: KEDA trigger
# ---------------------------------------------------------------------------

def stage_keda(client, model, threshold=5):
    header(f"KEDA TRIGGER — ramp until num_requests_waiting > {threshold}")

    if not VLLM_METRICS:
        print("  VLLM_METRICS_URL not set — skipping.")
        print("  Run:  kubectl port-forward svc/vllm-llama3 8000:80 -n default")
        print("  Then: export VLLM_METRICS_URL=http://localhost:8000")
        return None

    # long prompt to keep requests in flight long enough to build a queue
    prompt = LONG[0]
    triggered_at = None

    for c in range(5, 80, 5):
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=c)
        futs = [executor.submit(req_blocking, client, model, prompt, 400)
                for _ in range(c)]
        time.sleep(2.5)
        m       = vllm_metrics()
        waiting = int(m.get("vllm:num_requests_waiting", 0))
        running = int(m.get("vllm:num_requests_running", 0))
        cache   = m.get("vllm:gpu_cache_usage_perc", 0)
        print(f"  c={c:3d}  running={running:3d}  waiting={waiting:3d}  "
              f"gpu_cache={cache*100:5.1f}%")

        if waiting >= threshold:
            triggered_at = c
            print(f"\n  KEDA would fire here — queue={waiting} >= threshold={threshold}")
            executor.shutdown(wait=False)
            break

        concurrent.futures.wait(futs)
        executor.shutdown(wait=True)

    if triggered_at is None:
        print("  Queue never exceeded threshold — try increasing concurrency range.")
    return {"keda_trigger_concurrency": triggered_at, "threshold": threshold}


# ---------------------------------------------------------------------------
# Stage: cache
# ---------------------------------------------------------------------------

def stage_cache(client, model):
    header("REDIS CACHE — same prompt cold vs warm")
    probe = LONG[3]   # detailed technical prompt

    print("  Cold (first request, cache miss) ...")
    cold = req_blocking(client, model, probe, max_tokens=150)
    time.sleep(1)
    print("  Warm (identical prompt, expect cache hit) ...")
    warm = req_blocking(client, model, probe, max_tokens=150)

    speedup = cold["latency"] / warm["latency"] if warm["latency"] > 0 else 1
    saving  = round((1 - warm["latency"] / cold["latency"]) * 100, 1)

    print(f"\n  cold  {cold['latency']:.3f}s  |  warm  {warm['latency']:.3f}s")
    print(f"  speedup {speedup:.1f}x  |  {saving}% faster")
    if saving < 5:
        print("  NOTE: small speedup — LiteLLM cache may be off or TTL expired.")

    return {"cold_s": round(cold["latency"], 3),
            "warm_s": round(warm["latency"], 3),
            "speedup_x": round(speedup, 2),
            "saving_pct": saving}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="llama3")
    ap.add_argument("--stage", default="all",
                    choices=["all", "baseline", "ttft", "stress", "keda", "cache"])
    args = ap.parse_args()

    if not API_KEY:
        print("ERROR: set LITELLM_MASTER_KEY"); sys.exit(1)

    client = OpenAI(base_url=f"{LITELLM_URL}/v1", api_key=API_KEY)
    wait_for_server(LITELLM_URL)

    results  = {"timestamp": datetime.utcnow().isoformat(),
                "model": args.model}
    run_all  = args.stage == "all"

    if run_all or args.stage == "baseline":
        results["baseline"] = stage_baseline(client, args.model)

    if run_all or args.stage == "ttft":
        results["ttft"] = stage_ttft(client, args.model)

    if run_all or args.stage == "stress":
        results["stress"] = stage_stress(client, args.model)

    if run_all or args.stage == "keda":
        results["keda"] = stage_keda(client, args.model)

    if run_all or args.stage == "cache":
        results["cache"] = stage_cache(client, args.model)

    # Final summary
    header("FINAL SUMMARY")
    if "baseline" in results:
        b = results["baseline"]
        print(f"  Sequential p50/p99  :  {b['p50_s']}s / {b['p99_s']}s")
        print(f"  Single-request tok/s:  {b['mean_tok_per_s']}")

    if "ttft" in results and results["ttft"]:
        peak = results["ttft"][-1]
        print(f"  TTFT at c=50        :  p50={peak['ttft_p50_ms']}ms  "
              f"p99={peak['ttft_p99_ms']}ms")
        print(f"  TPOT at c=50        :  p50={peak['tpot_p50_ms']}ms")

    if "stress" in results:
        peak_r = max(results["stress"]["ramp"], key=lambda x: x["tok_per_s"])
        print(f"  Peak throughput     :  {peak_r['tok_per_s']} tok/s  "
              f"at c={peak_r['concurrency']}")
        print(f"  p99 at peak         :  {peak_r['p99_s']}s")
        print(f"  GPU cache at peak   :  {peak_r['gpu_cache']}%")

    if "keda" in results and results["keda"]:
        print(f"  KEDA fires at       :  c={results['keda']['keda_trigger_concurrency']}")

    if "cache" in results:
        c = results["cache"]
        print(f"  Cache speedup       :  {c['speedup_x']}x ({c['saving_pct']}% faster)")

    path = os.path.join(OUTPUT_DIR,
        f"bench_{args.model}_{datetime.utcnow().strftime('%Y%m%dT%H%M%S')}.json")
    with open(path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\n  Results saved → {path}")


if __name__ == "__main__":
    main()
