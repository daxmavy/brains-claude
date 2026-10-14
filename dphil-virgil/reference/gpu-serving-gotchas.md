# GPU jobs & model serving on Virgil — gotchas

Hard-won operational gotchas for running/serving models on Virgil (4×H100 80GB).
All observed in practice; each has a concrete fix.

## GPU-selection race on back-to-back launches
`virgil.sh bg --gpus N` picks GPUs by reading **current** occupancy. A model takes
tens of seconds to load before it allocates GPU memory — so two bg jobs launched a
few seconds apart both read the same GPU as free and **land on it together** →
OOM/contention. (Observed: two perplexity jobs both reported "using GPU 0".)

Fix: launch the first job, **wait until it actually occupies its GPU** before
launching the next, so the selector sees it busy and picks a different one:
```bash
virgil.sh bg job1 --gpus 1 -- '<cmd model A>'
# wait (remotely, so a flaky local ssh can't hang the gate) until GPU0 is taken:
virgil.sh run --gpus 0 -- \
  'for i in $(seq 1 30); do m=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0); [ "${m:-0}" -gt 5000 ] && break; sleep 5; done; echo "GPU0=${m}MiB"'
virgil.sh bg job2 --gpus 1 -- '<cmd model B>'   # now picks GPU1
```
Alternatively pin explicitly with `CUDA_VISIBLE_DEVICES` (remember
`CUDA_DEVICE_ORDER=PCI_BUS_ID`).

## vLLM on a single GPU (TP=1) — each model fails differently
Splitting a model across 2 GPUs (TP=2) gives ample KV/cache headroom; **TP=1 on one
card is tight** and the failure mode is model-specific:

- **Large dense models (e.g. gemma-4-31B) OOM the KV cache at long context.** At
  `max_model_len 16384`, TP=1 on 80 GB leaves too little for KV — vLLM aborts:
  *"To serve at least one request with the model's max seq len … KV cache … larger
  than available"*. Fix: drop `max_model_len` to what the task needs (8192 is plenty
  for selection / short prompts) and/or raise `gpu_memory_utilization` to ~0.93.
- **Mamba-hybrid models (e.g. Qwen3.6-27B) fail CUDA-graph capture under default
  concurrency.** vLLM's default `max_num_seqs=1024` exceeds the available Mamba
  cache blocks (e.g. only 281) on one GPU: *"max_num_seqs … exceeds available Mamba
  cache blocks"*. Fix: `--max-num-seqs 256`, and cap client-side concurrency for it.
  (The same model at high concurrency can also stall mid-run during Mamba kernel JIT
  — a per-model concurrency cap of ~8 fixes that too.)
- **MXFP4 models (e.g. gpt-oss-120b) serve fine in vLLM but OOM under transformers
  bf16.** The 120B fits TP=1 on 80 GB via vLLM's MXFP4 kernels, but
  `AutoModelForCausalLM(..., dtype=bfloat16)` tries to materialise ~240 GB → OOM.
  For perplexity / any HF (non-vLLM) use, load with the MXFP4/quantization config or
  `device_map`, not plain bf16.

## Ports on shared hosts
A common base port (often **8000**) may already be held by another user's service →
vLLM dies with *"Address already in use"*. Don't hardcode the port; probe for a free
one from a base, or pick a high base (8200+) and verify it's free first
(`ss -ltn | grep :PORT`). If `ss`/`netstat` can't show you the PID, the holder is
another user — pick a different port, don't kill it.

## Model cache locations differ
The shared cache and your private cache are different directories. The shared cache
is `/VData/resources/huggingface`, but a model you downloaded yourself may sit in a
private cache under `/VData/<username>`. Point `HF_HOME` at the
cache that holds the model, **or** pass an explicit `model_path` (with
`--served-model-name` so the served API id stays clean and there's no hub
re-download). `virgil.sh hf-ls <name>` checks the shared cache, which the skill sets as
`HF_HOME` automatically.

## `data/` is NOT mirrored — only code is
The code mirror (`run`/`bg`/`deploy`) sends **code only**; `data/` and `results/` are excluded. Any input a
remote job reads — a `--match params.json`, a prepared CSV — must be synced
separately (`sync-up`, `put`, or `scp`). A job that can't find `data/...` right after
a fresh mirror is almost always this.

## The shared conda env may lack a project dep
The `<your-env>` env is shared and may be missing a Python dep your code needs
(observed: `retrying`). On `ModuleNotFoundError`, `virgil.sh install <pkg>` (or
`uv pip install` into the active env) and re-run. You're free to modify the env.

## Orphaned vLLM after a job "finishes"
An asyncio job that doesn't close its async client cleanly can hang in teardown
(*"Event loop is closed"*), leaving a vLLM server **spinning on a GPU at ~100% util
while doing no work** — and any sequential queue waiting on that process stalls.
Symptom: results already written / job looks done, but the GPU stays pinned and the
process is still alive with no fresh output. Diagnose with `pgrep -af vllm.entrypoints`
plus GPU util vs actual row/checkpoint growth; kill the orphaned server **and its
`EngineCore` child** to free the GPU. (Prevent it in code by closing the async client
in-loop and force-exiting after results are persisted.)

## ssh to Virgil can hang on a VPN blip
A bare `ssh host "..."` inside a poll loop can **block indefinitely** on a stalled TCP
connection (flaky VPN), freezing the loop so it never sees completion. Always use
`ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2` for
hand-written remote checks so a blip fails fast and the loop retries; on a transient
exit-255, just retry. For long waits, prefer a scheduled self-wakeup over a
long-lived poll. (`virgil.sh` subcommands already wrap ssh sanely — this is for raw
ssh you write yourself.)

## Verify a serve actually works before a long run
A vLLM server reaching "ready" (health endpoint) is not proof it serves usefully —
boot can succeed and the first real request stall, or the model id can mismatch.
Before committing to a multi-hour run, send one test completion (`/v1/chat/completions`)
and confirm a sane response. Smoke EVERY new model tiny first
(a few docs/props) — the failure modes above all surface in a 2-minute smoke.

## GPU policy
- A GPU with **any** other user's process on it is off-limits — never co-locate.
- Prefer GPUs 1–3 when you have a free choice: GPU 0 is set aside as a pilot device
  in the cluster's configuration.
- Virgil may use all 4 GPUs, but only with explicit user approval
  (`--allow-all-gpus`). Never monopolise by default.
