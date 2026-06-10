---
name: brains
description: >-
  Run GPU/CPU-heavy work on "Brains", the Oxford OII department GPU server
  (brains.oii.ox.ac.uk), instead of locally. Use WHENEVER a task
  needs a GPU — training, fine-tuning, running or serving an LLM, large-batch or
  accelerated inference, embeddings at scale, any CUDA/PyTorch/vLLM workload — and
  also for SSHing to Brains, checking the Oxford VPN, syncing experiment
  data/results to this Mac, reusing the shared HuggingFace cache, or setting up a
  project spanning local + Brains. When a task needs a GPU the agent should
  connect, deploy the repo, write the script, check GPU availability, and run it
  autonomously. Triggers: "needs a GPU", "train/fine-tune/run inference on",
  "Brains", "Virgil", "the GPU server", "A100/L40S/H100", "ssh to brains",
  "sync results", "is the VPN on". Enforces: GPU work runs on Brains first,
  falling back to Virgil (4x H100) only onto completely-empty GPUs, the
  no-monopoly GPU policy, /data-not-/home, VPN preflight, local/remote split.
---

# Brains GPU server

Brains is a department GPU box: `ssh <username>@brains.oii.ox.ac.uk`, reachable
**only over the Oxford VPN** (Cisco Secure Client → `vpn.ox.ac.uk`). Hardware:
2× A100 80GB + 2× L40S, run by **direct execution** (not Slurm). A second host,
**Virgil** (`virgil.oii.ox.ac.uk`, 4× H100 80GB), is used as **automatic
fallback** when Brains can't satisfy a GPU request — **priority is always
Brains > Virgil**, and on Virgil a GPU is used **only if nobody has any process
on it** (see the Virgil section below).

**Everything goes through one CLI** (`scripts/brains.sh`), which guarantees the
invariants below on every call. Invoke it by absolute path:

```
~/.claude/skills/brains/scripts/brains.sh <command> [args]
```

## First-use setup

On a fresh install, confirm setup before the first remote action — the full
checklist (what to verify, and what only the user can do) is in
[`reference/setup.md`](reference/setup.md). In brief: `config.sh` holds the user's
own `BRAINS_USER` + `BRAINS_CONDA_ENV`; passwordless SSH to Brains works; their
conda env exists; and **GitHub credentials are set up both on the laptop and on
Brains** — the git code-sync needs auth on both ends and Brains has none by
default, so `deploy`/`init`/push-from-Brains (and private-repo pulls) fail until a
key is added on Brains. `brains.sh check` confirms connectivity. A few steps only
the user can finish — adding an SSH key to GitHub, `ssh-copy-id`, `gh auth login` —
so guide them rather than assuming.

## When a task needs a GPU (default behaviour)

GPU/CUDA work does **not** run on this Mac — route it to Brains autonomously:
1. Ensure the project is set up (`init` once) and current (`deploy` to push
   code). Connectivity is auto-checked on every command — no manual preflight.
2. Write the compute script into `pipelines/` (commit + `deploy`).
3. **Check GPU availability and claim only what you need** — `brains.sh gpus`,
   then run with `--gpus N` (see the GPU policy below).
4. `bg` for anything long; `sync-down` results when done.

Decide N from the workload (rough: a 7–8B model in bf16 ≈ 1 GPU; a 70B ≈ 2×
A100). Don't guess high "to be safe" — claim the minimum.

## Golden rules (do not break these)

1. **Preflight is automatic.** Every `brains.sh` command (except the local ones —
   `help`/`config`/`vpn`/`check`) auto-runs the VPN + reachability preflight
   first: **silent when online**, and it aborts with a clear diagnosis when not.
   VPN state is read from the **Cisco client**, never by trying to reach Brains,
   so "VPN down" (exit 1) is never confused with "Brains unreachable" (exit 2).
   You never run `check` by hand — `brains.sh check`/`vpn` just stay available for
   explicit diagnosis.
2. **Heavy files live on `/data/<username>`, never `/home`.** `/home` is ~96% full
   (24 GB). Repos, data, outputs, venvs, caches all go under `/data/<username>`.
3. **Only ever write inside `/data/<username>`, `/home/<username>`, or (additively)
   the shared HF cache.** Never modify other users' files or system paths.
4. **Check the shared HuggingFace cache before downloading.** `HF_HOME` is set to
   `/data/resource/huggingface` automatically; use `brains.sh hf-ls <model>` to
   see what's already there. New downloads add to the shared cache (never delete
   others' entries).
5. **Code travels by git; data travels by rsync.** One repo cloned both sides.
   Never commit `data/`/`results/`. Pull results to local for **all
   visualisation** — viz happens locally so you can iterate without Brains.
6. **GPU policy — check first, never monopolise.** Before claiming GPUs, check
   who's on them (`brains.sh gpus`). Request the **minimum** with `--gpus N`; the
   tool refuses and prints a per-user occupancy report if fewer than N are free —
   when that happens, **tell the user who is occupying the GPUs and how many each
   holds** instead of proceeding. **Never occupy all GPUs of a host**: that needs
   `--allow-all-gpus`, which you pass *only* after explicitly asking the user and
   getting approval. **On Virgil, never touch a GPU that has anyone's process on
   it** — the tool enforces this (exclusive rule), do not work around it.

## Per-project setup

Local repos can live anywhere. Each is linked to Brains by a `.brains` file at
its root (created by `init`, safe to commit). From your local repo root:

```
~/.claude/skills/brains/scripts/brains.sh init <project-name>
```

This writes `.brains` (mapping the repo to `/data/<username>/<project-name>`),
adds gitignore entries for `data/`/`results/`/`.venv/`, scaffolds
`pipelines/ analysis/ data/ results/`, and on Brains creates the project dir,
the `/data` caches, and clones the repo (if it has a GitHub `origin`).

## Common workflows

| Goal | Command |
|---|---|
| Is the VPN on? (Brains-independent) | `brains.sh vpn` |
| Full preflight (VPN + reachability) | `brains.sh check` |
| GPU free/busy + who's using them | `brains.sh gpus` |
| Can I get N free GPUs right now? | `brains.sh gpu-check <n>` |
| Is a model already cached? | `brains.sh hf-ls <name>` |
| Sync code to Brains | `brains.sh deploy` (git push + remote pull) |
| Quick job on 1 GPU | `brains.sh run --gpus 1 -- python pipelines/x.py` |
| Long job on 2 GPUs (survives disconnect) | `brains.sh bg train --gpus 2 -- python pipelines/train.py` |
| Use ALL GPUs (only after user approves) | `brains.sh bg big --gpus 4 --allow-all-gpus -- …` |
| Watch / stop a job | `brains.sh logs train` · `brains.sh stop train` · `brains.sh jobs` |
| Pull results for local viz | `brains.sh sync-down` |
| Push input data to Brains | `brains.sh sync-up data` |
| Fetch one remote file | `brains.sh get results/foo.json` |
| Push one file to Brains | `brains.sh put ./config.yaml` |
| Interactive shell on Brains | `brains.sh shell` |

Run `brains.sh help` for the full list. **Default heavy GPU/CPU work to Brains;
do all plotting/analysis locally on synced data.** Use `--gpus N` (the tool picks
free GPUs and refuses if too few are free) and `bg` for anything over a minute.

## Python on Brains

All remote commands run inside the **`<your-env>` conda env** (the skill activates it
automatically — conda isn't loaded in non-interactive SSH otherwise). Manage
dependencies with **uv**, which installs into the active conda env:
- `brains.sh install <pkgs>` — e.g. `brains.sh install 'torch>=2.4' transformers`
- or inside a job: `uv pip install <pkgs>` then run `python …`

You are free to modify the `<your-env>` env as needed. uv/pip caches go to `/data`.

## Virgil (fallback host)

Virgil = `virgil.oii.ox.ac.uk`, 4× H100 80GB, same Oxford VPN, same username.
The CLI handles it automatically — same commands, no separate tooling:

- **Priority Brains > Virgil.** A `--gpus N` request resolves on Brains first;
  only if Brains has too few usable GPUs does it fall back to Virgil. Force it
  with `--host virgil` (run/bg/install) when explicitly asked to.
- **Exclusive rule on Virgil:** a GPU counts as usable **only with zero
  processes on it** (and ~zero memory/util). It is critical not to block or
  slow anyone's work on Virgil — never co-locate there, never work around the
  refusal.
- **Code reaches Virgil by rsync** from the laptop (automatic before each run;
  no git/GitHub credentials on Virgil needed). Git stays Brains/local-canonical.
- **Paths differ:** big disk is `/VData/<username>` (NOT `/data`, which doesn't
  exist there; `/` and `/scratch` are nearly full — never write big files
  outside `/VData`). Shared HF cache: `/VData/resources/huggingface` — set
  automatically. Same conda env name, auto-activated.
- `jobs`/`logs`/`stop`/`sync-down` check **both hosts** — nothing extra to do.
- One-time setup per user: `ssh-copy-id <username>@virgil.oii.ox.ac.uk` and a
  conda env there (`conda create -n <your-env> python=3.11 -y`).

## Gotchas

- **GPU index mapping (handled — but know it):** CUDA's default device order
  (`FASTEST_FIRST`) does **not** match `nvidia-smi`'s. On Brains, nvidia-smi GPU
  0/1 (A100) are CUDA 2/3 by default, and the L40S come first — so a naive
  `CUDA_VISIBLE_DEVICES=0` lands on an **L40S, not the A100 you meant**. The skill
  sets `CUDA_DEVICE_ORDER=PCI_BUS_ID` in every job so CUDA indices match nvidia-smi
  and the `gpus`/`gpu-check` selector. If you ever run a job *outside* `brains.sh`,
  export `CUDA_DEVICE_ORDER=PCI_BUS_ID` yourself.

## Reference (read when needed)

- `reference/architecture.md` — local/remote split, canonical locations, the
  `.brains` config, directory layout, data flow, how each requirement is met.
- `reference/versioning.md` — the one-repo workflow, code-vs-data, keeping local
  and Brains in sync, run provenance, the gitignore template.
- `reference/remote-environment.md` — why the env preamble exists (non-interactive
  SSH skips `.bashrc`), the shared HF cache, cache redirection, GPU usage.
- `reference/setup.md` — first-run setup + the agent checklist (what to verify and
  what to request from the user): config, passwordless SSH, conda env, and GitHub
  credentials (local + on Brains).
