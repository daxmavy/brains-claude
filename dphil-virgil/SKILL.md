---
name: virgil
description: >-
  Run GPU/CPU-heavy work on "Virgil", the Oxford OII 4x H100 GPU server
  (virgil.oii.ox.ac.uk), instead of locally. Use WHENEVER a task needs a GPU —
  training, fine-tuning, running or serving an LLM, large-batch or accelerated
  inference, embeddings at scale, any CUDA/PyTorch/vLLM workload — and also for
  SSHing to Virgil, checking the Oxford VPN, syncing experiment data/results to
  this Mac, reusing the shared HuggingFace cache, or setting up a project
  spanning local + Virgil. When a task needs a GPU the agent should connect,
  mirror the repo, write the script, check GPU availability, and run it
  autonomously. Triggers: "needs a GPU", "train/fine-tune/run inference on",
  "Virgil", "the GPU server", "H100", "ssh to virgil", "sync results", "is the
  VPN on". Enforces: only completely-free GPUs, the no-monopoly GPU policy,
  /VData-not-/home, VPN preflight, local/remote split.
---

# Virgil GPU server

Virgil is a department GPU box: `ssh <username>@virgil.oii.ox.ac.uk`, reachable
**only over the Oxford VPN** (Cisco Secure Client → `vpn.ox.ac.uk`). Hardware:
4× H100 80GB, 128 threads, 503 GB RAM, run by **direct execution** (not Slurm).
No sudo, no Docker; singularity/apptainer is available.

**Everything goes through one CLI** (`scripts/virgil.sh`), which guarantees the
invariants below on every call. Invoke it by absolute path:

```
~/.claude/skills/virgil/scripts/virgil.sh <command> [args]
```

## First-use setup

On a fresh install, confirm setup before the first remote action — the full
checklist (what to verify, and what only the user can do) is in
[`reference/setup.md`](reference/setup.md). In brief: `config.sh` holds the user's
own `VIRGIL_USER` + `VIRGIL_CONDA_ENV`; passwordless SSH to Virgil works; their
conda env exists on `/VData`. **No GitHub credentials are needed on Virgil** —
code reaches it by rsync from the laptop. `virgil.sh check` confirms
connectivity. `ssh-copy-id` needs the user's password, so only they can do it.

## When a task needs a GPU (default behaviour)

GPU/CUDA work does **not** run on this Mac — route it to Virgil autonomously:
1. Ensure the project is set up (`init` once). Connectivity is auto-checked on
   every command, and **code syncs itself**: every `run`/`bg` mirrors the laptop
   working tree first, so a remote job never runs stale code.
2. Write the compute script into `pipelines/`.
3. **Check GPU availability and claim only what you need** — `virgil.sh gpus`,
   then run with `--gpus N` (see the GPU policy below).
4. `bg` for anything long; `sync-down` results when done.

Decide N from the workload (rough: a 7–8B model in bf16 ≈ 1 GPU; a 70B ≈ 2×
H100). Don't guess high "to be safe" — claim the minimum.

## Golden rules (do not break these)

1. **Preflight is automatic.** Every remote `virgil.sh` command first checks the
   VPN (read from the **Cisco client**, never by contacting Virgil) and then
   Virgil's SSH port, so "VPN down" (exit 1) is never confused with "Virgil
   unreachable" (exit 2). Silent when online.
2. **Heavy files live on `/VData/<username>`, never `/home` or `/scratch`.**
   Projects, data, outputs, envs and caches all go under `/VData/<username>`.
   `/VData` is large but shared and often nearly full — check `df -h /VData`
   before writing anything big, and tell the user if it is tight.
3. **Only ever write inside `/VData/<username>`, `/home/<username>`, or
   (additively) the shared HF cache.** Never modify other users' files or system
   paths.
4. **Check the shared HuggingFace cache before downloading.** `HF_HOME` is set to
   `/VData/resources/huggingface` automatically; `virgil.sh hf-ls <model>` shows
   what's there. New downloads add to it (never delete others' entries).
5. **The laptop is canonical; Virgil is a mirror.** Code is rsynced up before
   every run (`--delete` keeps it exact); `data/` and `results/` are never sent
   or deleted. **Never edit code on Virgil** — the next run overwrites it. Git is
   for version control on the laptop only. Pull results to local for **all
   visualisation**.
6. **GPU policy — only completely-free GPUs, never monopolise.** A GPU counts as
   usable **only if nobody has any process on it**; never co-locate with someone
   else's work, and never work around a refusal. Check first (`virgil.sh gpus`)
   and request the **minimum** with `--gpus N`. If too few are free, the tool
   refuses with a per-user occupancy report — **tell the user who holds the GPUs
   and how many each** instead of proceeding. **Never occupy all 4 GPUs** without
   `--allow-all-gpus`, which you pass only after the user explicitly approves.
   Prefer GPUs 1–3 when you have a free choice: GPU 0 is set aside as a pilot
   device in the cluster's configuration.

## Per-project setup

Local repos can live anywhere. Each is linked to Virgil by a `.virgil` file at
its root (created by `init`, safe to commit). From your local repo root:

```
~/.claude/skills/virgil/scripts/virgil.sh init <project-name>
```

This writes `.virgil` (mapping the repo to `/VData/<username>/<project-name>`),
adds gitignore entries for `data/`/`results/`/`.venv/`, scaffolds
`pipelines/ analysis/ data/ results/`, creates the remote dir and caches, and
mirrors the code there.

## Common workflows

| Goal | Command |
|---|---|
| Is the VPN on? | `virgil.sh vpn` |
| Full preflight (VPN + reachability) | `virgil.sh check` |
| GPU free/busy + who's using them | `virgil.sh gpus` |
| Can I get N free GPUs right now? | `virgil.sh gpu-check <n>` |
| Is a model already cached? | `virgil.sh hf-ls <name>` |
| Mirror code to Virgil now | `virgil.sh deploy` (run/bg do it automatically) |
| Quick job on 1 GPU | `virgil.sh run --gpus 1 -- python pipelines/x.py` |
| Long job on 2 GPUs (survives disconnect) | `virgil.sh bg train --gpus 2 -- python pipelines/train.py` |
| Use ALL GPUs (only after user approves) | `virgil.sh bg big --gpus 4 --allow-all-gpus -- …` |
| Watch / stop a job | `virgil.sh logs train` · `virgil.sh stop train` · `virgil.sh jobs` |
| Pull results for local viz | `virgil.sh sync-down` |
| Push input data | `virgil.sh sync-up data` |
| Fetch / push one file | `virgil.sh get results/foo.json` · `virgil.sh put ./config.yaml` |
| Interactive shell on Virgil | `virgil.sh shell` |

Run `virgil.sh help` for the full list. **Do all plotting/analysis locally on
synced data.** Use `bg` for anything over a minute.

## Python on Virgil

All remote commands run inside **your conda env** (`VIRGIL_CONDA_ENV`, ideally a
path under `/VData/<username>/envs/`); the skill activates it automatically —
conda isn't loaded in non-interactive SSH otherwise. Manage dependencies with
**uv**, which installs into the active conda env:
- `virgil.sh install <pkgs>` — e.g. `virgil.sh install 'torch>=2.4' transformers`
- or inside a job: `uv pip install <pkgs>` then run `python …`

uv/pip caches go to `/VData/<username>/.cache`.

## Gotchas

- **Set `CUDA_DEVICE_ORDER=PCI_BUS_ID` outside the tool.** The skill sets it in
  every job so CUDA indices match `nvidia-smi` and the GPU selector. If you ever
  run a job *outside* `virgil.sh`, export it yourself.
- **GPU-selection race on back-to-back launches:** two `bg --gpus 1` jobs started a
  few seconds apart can both pick the **same** GPU — the selector reads occupancy
  before the first model has allocated memory. Launch one, **wait until it occupies
  its GPU** (poll `nvidia-smi` memory) *then* launch the next, or pin explicitly.
- **Smoke every new model tiny first, and confirm a vLLM server actually answers a
  test completion** — "ready" ≠ "serving". TP=1 single-GPU serving has
  model-specific failures: big dense models OOM the KV cache at long `max_model_len`
  (cap it ~8192); Mamba-hybrids (Qwen3.6) need `--max-num-seqs 256`; MXFP4 models
  (gpt-oss) serve in vLLM but OOM under transformers bf16.
- **Ports & caches on a shared host:** a base port (often 8000) may be another user's
  — probe for a free one, don't hardcode. A model may be in the shared cache *or*
  your private one — set `HF_HOME` or pass an explicit `model_path`
  (+`--served-model-name`).
- **`data/` is not mirrored** — sync input files (`--match` params, CSVs) with
  `sync-up`/`put`, or a fresh remote job won't find them. Your env may also lack a
  dep (`virgil.sh install <pkg>` on `ModuleNotFound`).
- **Orphaned vLLM after a job "finishes":** an asyncio teardown hang can leave a
  server pinning a GPU at 100% util doing nothing, stalling any queue behind it —
  check `pgrep -af vllm.entrypoints` + util vs real progress, and kill the server
  **and its EngineCore**. For hand-written remote checks use
  `ssh -o ConnectTimeout=10 -o ServerAliveInterval=5` so a VPN blip fails fast
  rather than hanging the poll (retry once on a transient exit-255).
- **Detailed versions of all the above (exact error strings + fixes):**
  [`reference/gpu-serving-gotchas.md`](reference/gpu-serving-gotchas.md).

## Reference (read when needed)

- `reference/architecture.md` — local/remote split, canonical locations, the
  `.virgil` config, directory layout, data flow.
- `reference/versioning.md` — the laptop-canonical mirror, code-vs-data, run
  provenance, the gitignore template.
- `reference/remote-environment.md` — why the env preamble exists (non-interactive
  SSH skips `.bashrc`), the shared HF cache, cache redirection, GPU usage, disks.
- `reference/setup.md` — first-run setup + the agent checklist (what to verify and
  what to request from the user).
- `reference/gpu-serving-gotchas.md` — operational gotchas for running/serving
  models: the GPU-selection race, per-model TP=1 serving failures, ports/caches on
  a shared host, `data/` not mirrored, orphaned-vLLM detection, ssh-over-VPN
  timeouts. Read before a non-trivial serve/run.
