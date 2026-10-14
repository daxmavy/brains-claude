# Remote environment on Virgil

## The non-interactive shell gotcha (why the preamble exists)

`virgil.sh` runs commands as `ssh host '…'` — a **non-interactive** shell, and
`~/.bashrc` starts with the standard guard that returns early when the shell is
not interactive:

```bash
case $- in *i*) ;; *) return;; esac   # return immediately if not interactive
```

So for agent-launched commands **`.bashrc` is skipped entirely**: `HF_HOME`,
conda and any `PATH` tweaks are absent unless we set them ourselves. (Your
interactive `ssh` sessions and tmux windows *do* get `.bashrc`, so this only bites
automated commands.)

`virgil.sh` therefore injects a fixed **environment preamble** into every remote
command:

```bash
export HF_HOME=/VData/resources/huggingface            # shared cache (read+write)
export HF_HUB_CACHE=/VData/resources/huggingface/hub
export HF_DATASETS_CACHE=/VData/resources/huggingface/datasets
export UV_CACHE_DIR=/VData/<username>/.cache/uv        # caches OFF /home …
export PIP_CACHE_DIR=/VData/<username>/.cache/pip
export TORCH_HOME=/VData/<username>/.cache/torch
export TRITON_CACHE_DIR=/VData/<username>/.cache/triton
export XDG_CACHE_HOME=/VData/<username>/.cache         # … catch-all for the rest
export CUDA_DEVICE_ORDER=PCI_BUS_ID                    # CUDA indices == nvidia-smi
source /opt/anaconda/etc/profile.d/conda.sh && conda activate <your-env>
```

HF reuses the **shared cache**; package/model caches land on `/VData` instead of
`/home`; CUDA device numbering matches `nvidia-smi`; and Python runs in your env.

## Shared HuggingFace cache

`/VData/resources/huggingface` is a large, active, group-writable cache shared
across the department. Because `HF_HOME` points there, `from_pretrained(...)`,
`hf download` and `load_dataset(...)` **reuse anything already present**.

- **Always check before downloading:** `virgil.sh hf-ls <name>` (e.g.
  `virgil.sh hf-ls qwen`). If it's listed, it's already on disk.
- New downloads add to the shared cache. **Never delete or edit other users'
  entries** — additive only.
- Gated models still need a HF token in the session (`HF_TOKEN` /
  `huggingface-cli login`); the cache doesn't bypass licensing.

## Python: your conda env + uv

Every `virgil.sh run` / `bg` / `install` runs inside your conda env
(`VIRGIL_CONDA_ENV` in `config.sh`). Create it on `/VData` and address it by
path, so it never lands in `/home`:

```bash
ssh <username>@virgil.oii.ox.ac.uk \
  'source /opt/anaconda/etc/profile.d/conda.sh && conda create -p /VData/<username>/envs/<env> python=3.11 -y'
# then in config.sh: VIRGIL_CONDA_ENV="/VData/<username>/envs/<env>"
```

Manage dependencies with **uv**, which auto-targets the active conda env:

```bash
virgil.sh install 'torch>=2.4' transformers
virgil.sh run --gpus 1 -- python pipelines/train.py
```

## GPUs (direct execution, exclusive)

No Slurm — you run directly on the node and share its 4× H100 with other users.
The rule here is strict: **a GPU is usable only if nobody has any process on
it** (and its memory/utilisation are near zero, which also catches jobs whose
processes don't show in `nvidia-smi`). Never co-locate with someone's work.

- **See who's on:** `virgil.sh gpus` — per-GPU free/busy, the processes + users,
  and a per-user summary. `virgil.sh gpu-check <n>` answers "can I get n GPUs
  now?" and names who's blocking if not.
- **Claim the minimum:** `--gpus N` selects N free GPUs and pins
  `CUDA_VISIBLE_DEVICES`. If fewer than N are free the request is **refused** —
  relay to the user *who* holds the GPUs and *how many* each, rather than waiting
  on or stomping someone's job.
- **Explicit indices:** `--gpu 2,3` requests those GPUs (still checked).
- **Prefer GPUs 1–3:** GPU 0 is set aside as a pilot device in the cluster's
  configuration.
- **Never all of them without permission:** `--gpus 4` is refused unless
  `--allow-all-gpus` is passed, and you pass that *only* after the user approves.
- **Persist long jobs:** `bg` runs inside tmux so the job survives SSH disconnect;
  logs stream to `results/logs/<job>.log`. Monitor with `virgil.sh logs <job>`,
  stop with `virgil.sh stop <job>`, attach via `virgil.sh shell` then
  `tmux attach -t virgil_<job>`.

## Disks

| Mount | Use for |
|---|---|
| `/home` | dotfiles/config only |
| `/scratch` | nothing big — small and often full |
| `/VData` | **everything heavy** — but shared and often nearly full: `df -h /VData` first |

If a job writes large files, keep its output under `/VData/<username>` (the
project `results/` already is). Watch for libraries that default to `~` — the
cache variables above cover the common ones, but check new tools.
