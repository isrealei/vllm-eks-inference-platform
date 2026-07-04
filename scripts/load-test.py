import warnings
warnings.filterwarnings("ignore")

import time, requests, json, os, math, sys

VLLM_URL = "https://vllm.slcdev.cc"
os.makedirs("outputs", exist_ok=True)

print("Waiting for vLLM server...")
for attempt in range(60):
    try:
        r = requests.get(f"{VLLM_URL}/v1/models", timeout=5)
        if r.status_code == 200:
            MODEL = r.json()["data"][0]["id"]
            break
    except requests.ConnectionError:
        pass
    time.sleep(5)
    if attempt % 6 == 5:
        print(f"  Still waiting... ({(attempt + 1) * 5}s elapsed)")
else:
    raise RuntimeError(
        "vLLM server not reachable after 5 minutes."
    )

print(f"Connected to {VLLM_URL} — model: {MODEL}")


from openai import OpenAI
client = OpenAI(base_url=f"{VLLM_URL}/v1", api_key="unused")
start = time.time()
resp = client.chat.completions.create(
    model=MODEL,
    messages=[{"role": "user", 
               "content": "What is PagedAttention in one sentence?"}],
    max_tokens=80,
    temperature=0.7,
    top_p=0.8,
    extra_body={"top_k": 20, 
                "chat_template_kwargs": {"enable_thinking": False}},
)
elapsed = time.time() - start

print(f"Response ({elapsed:.2f}s, {resp.usage.completion_tokens} tokens):")
print(resp.choices[0].message.content)
print(f"\nUsage: {resp.usage.prompt_tokens} prompt + "
      f"{resp.usage.completion_tokens} completion = {resp.usage.total_tokens} total")

def get_vllm_metrics(base_url=VLLM_URL):
    """Scrape vLLM Prometheus /metrics and return {name: value}."""
    r = requests.get(f"{base_url}/metrics")
    metrics = {}
    for line in r.text.split("\n"):
        if line.startswith("#") or not line.strip():
            continue
        name = line.split("{")[0].split()[0]
        try:
            metrics[name] = float(line.split()[-1])
        except (ValueError, IndexError):
            continue
    return metrics

metrics = get_vllm_metrics()
print("Current vLLM Metrics:")
for key in ["vllm:num_requests_running", "vllm:num_requests_waiting",
            "vllm:gpu_cache_usage_perc", "vllm:cpu_cache_usage_perc",
            "vllm:prompt_tokens_total", "vllm:generation_tokens_total"]:
    if key in metrics:
        print(f"  {key.replace('vllm:', '')}: {metrics[key]:g}")

with open("outputs/metrics_snapshot.json", "w") as f:
    json.dump(metrics, f, indent=2)
print(f"\nFull metrics saved to outputs/metrics_snapshot.json")



import concurrent.futures

prompts = [
    "What is quantization?",
    "Explain KV caching briefly.",
    "What is continuous batching?",
    "Why is LLM inference memory-bound?",
    "What is PagedAttention?",
]

def _ask(prompt):
    return client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": prompt}],
        max_tokens=60, temperature=0.7,
        extra_body={"chat_template_kwargs": {"enable_thinking": False}},
    )

before = get_vllm_metrics()
print(f"Sending {len(prompts)} concurrent requests...\n")
start = time.time()

with concurrent.futures.ThreadPoolExecutor(
    max_workers=len(prompts)) as pool:
    futures = {pool.submit(_ask, p): p for p in prompts}
    time.sleep(0.5)
    during = get_vllm_metrics()
    running = during.get("vllm:num_requests_running", "--")
    waiting = during.get("vllm:num_requests_waiting", "--")
    print(f"  [mid-flight]  running: {running}  |  waiting: {waiting}")

    for f in concurrent.futures.as_completed(futures):
        resp = f.result()
        print(f"  done: \"{futures[f][:40]}\" -> {resp.usage.completion_tokens} tokens")

elapsed = time.time() - start
after = get_vllm_metrics()
tokens = after.get("vllm:generation_tokens_total", 0) - before.get(
    "vllm:generation_tokens_total", 0)

print(f"\nAll {len(prompts)} completed in {elapsed:.2f}s")
if tokens > 0:
    print(f"Tokens generated: {tokens:g}  |  ~{tokens / elapsed:.1f} tokens/s")