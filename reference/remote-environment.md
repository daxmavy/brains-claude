# Remote environment on Brains

## The non-interactive shell gotcha (why the preamble exists)

`brains.sh` runs commands as `ssh host '…'` — a **non-interactive** shell. On
Brains, `~/.bashrc` starts with the standard guard:

```bash
case $- in *i*) ;; *) return;; esac   # return immediately if not interactive
```

So for agent-launched commands, **`.bashrc` is skipped entirely** — verified:
`ssh host 'printenv HF_HOME'`, `ssh host 'bash -lc printenv HF_HOME'`, and
`source ~/.bashrc; printenv HF_HOME` all return empty. That means `HF_HOME`,
conda, and the user's `PATH` tweaks are **not** present unless we set them
ourselves. (Your interactive `ssh` sessions and tmux windows *do* get `.bashrc`,
so this only bites automated commands.)

`brains.sh` therefore injects a fixed **environment preamble** into every remote
command:

```bash
export HF_HOME=/data/resource/huggingface          # shared cache (read+write)
export HF_HUB_CACHE=/data/resource/huggingface/hub
export HF_DATASETS_CACHE=/data/resource/huggingface/datasets
export UV_CACHE_DIR=/data/shil6647/.cache/uv        # caches OFF /home …
export PIP_CACHE_DIR=/data/shil6647/.cache/pip
export TORCH_HOME=/data/shil6647/.cache/torch
export TRITON_CACHE_DIR=/data/shil6647/.cache/triton
export XDG_CACHE_HOME=/data/shil6647/.cache         # … catch-all for the rest
export CUDA_DEVICE_ORDER=PCI_BUS_ID                 # CUDA indices == nvidia-smi (see GPUs)
source /opt/anaconda/etc/profile.d/conda.sh && conda activate daxmavy   # the work env
```

This single mechanism satisfies several requirements at once: HF reuses the
**shared cache**; package/model caches are redirected onto `/data` so the nearly
full `/home` (24 GB free) never fills up; CUDA device numbering is made consistent
with `nvidia-smi` (see GPUs); and Python runs in the **`daxmavy`** env.

## Shared HuggingFace cache

`/data/resource/huggingface` is a large, active, group-writable cache shared
across the department (Llama, DeepSeek, Aya, Qwen, many datasets, …). Because
`HF_HOME` points there, `from_pretrained(...)`, `hf download`, and
`load_dataset(...)` **automatically reuse anything already present** — no
re-download.

- **Always check before downloading:** `brains.sh hf-ls <name>` (e.g.
  `brains.sh hf-ls qwen`). If it's listed, it's already on disk.
- New downloads add to the shared cache (helping everyone). **Never delete or
  edit other users' entries** — additive only.
- Gated models still need a HF token in the session
  (`HF_TOKEN` / `huggingface-cli login`); the cache doesn't bypass licensing.

## Python: conda `daxmavy` + uv

Every `brains.sh run` / `bg` / `install` command runs inside the **`daxmavy`**
conda env (`/opt/anaconda/envs/daxmavy`, Python 3.11) — the skill sources conda
and activates it, since conda isn't loaded in non-interactive SSH. Manage
dependencies with **uv**, which auto-targets the active conda env:

```bash
brains.sh install 'torch>=2.4' transformers      # uv pip install into daxmavy
brains.sh run --gpus 1 -- python pipelines/train.py
```

You are free to modify the `daxmavy` env. uv/pip caches go to `/data`. There's no
per-project venv — `daxmavy` is the shared env for all work. (To install inside a
job instead of via `brains.sh install`, just `uv pip install <pkgs>` — uv detects
the active conda env.)

## GPUs (direct execution, shared, Brains-only)

No Slurm gating — you run directly on the Brains node and **share its 4 GPUs with
other users**. **Never use the Virgil node** (it's on the same Slurm cluster but
out of scope). GPUs 0–1 are A100 80GB (often busy); 2–3 are L40S 46GB.

**Always check before claiming, and never monopolise:**

- **See who's on:** `brains.sh gpus` — per-GPU free/busy, the processes + users,
  and a per-user occupancy summary. `brains.sh gpu-check <n>` answers "can I get
  n free GPUs right now?" and names who's blocking if not.
- **Claim the minimum:** `--gpus N` selects N *free* GPUs and pins
  `CUDA_VISIBLE_DEVICES`. If fewer than N are free the request is **refused** with
  the occupancy report — relay to the user *who* is occupying the GPUs and *how
  many* each holds, rather than waiting on or stomping someone's job. A GPU is
  **usable** if it has plenty of free memory (≥ ~40 GB) and low utilisation
  (≤ 20%), even if another user has a small process on it — so the agent may share
  a lightly-used GPU. Size your job to the free memory shown. Tune the thresholds
  via `BRAINS_GPU_MIN_FREE_MIB` / `BRAINS_GPU_MAX_UTIL`.
- **Explicit indices:** `--gpu 2,3` requests those specific GPUs (still checked
  for freeness and policy).
- **Never all of them without permission:** requesting all 4 (`--gpus 4`) is
  refused unless `--allow-all-gpus` is passed — and you pass that *only* after the
  user explicitly approves taking the whole machine.
- **Index mapping is handled (important):** the preamble exports
  `CUDA_DEVICE_ORDER=PCI_BUS_ID` so CUDA's device indices match `nvidia-smi` (and
  the selector). Without it, CUDA's default `FASTEST_FIRST` order lists the L40S
  first, so `CUDA_VISIBLE_DEVICES=0` would hit an **L40S, not nvidia-smi's A100
  #0** — verified on this box. Only a footgun if you run jobs outside `brains.sh`.
- **Persist long jobs:** `bg` runs inside tmux so the job survives SSH disconnect;
  logs stream to `results/logs/<job>.log`. Monitor with `brains.sh logs <job>`,
  stop with `brains.sh stop <job>`. Attach interactively via `brains.sh shell`
  then `tmux attach -t brains_<job>`.

## Disk reality

| Mount | Size | Free | Use for |
|---|---|---|---|
| `/home` | 598 G | ~24 G (96% full) | dotfiles/config only |
| `/data` | 9.1 T | ~1.1 T | **everything heavy** |

If a job writes large files, make sure its output path is under
`/data/shil6647` (the project `results/` already is). Watch out for libraries
that default to `~` — the cache env vars above cover the common ones, but check
new tools.
