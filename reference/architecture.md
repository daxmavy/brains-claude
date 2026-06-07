# Architecture: local ↔ Brains

## The split

```
   LOCAL (this Mac)                         BRAINS (brains.oii.ox.ac.uk)
   ─────────────────                        ───────────────────────────
   • all visualisation / plotting           • all GPU/CPU-heavy compute
   • notebooks, analysis, writing           • training / inference / sims
   • git source of truth (push)             • git working copy (pull, run)
   • results/ (synced FROM Brains)          • results/ (written here)
   • data/ subset (optional)               • data/ (full datasets)

            code  ──────── git (GitHub) ────────►  code
            data  ◄─────── rsync (brains.sh) ─────  results
```

Heavy work runs on Brains; its outputs are pulled to local so analysis and
figures can be iterated **without** a Brains connection. This is requirement 5:
a clear interface, with experimental data copied to local by default.

## Canonical locations

| What | Where |
|---|---|
| Project repo on Brains | `/data/shil6647/<project>` (**not** `/home`) |
| Project repo on local | anywhere; linked by the `.brains` file at its root |
| Big data / outputs / venvs / caches on Brains | under `/data/shil6647` |
| Shared HuggingFace cache | `/data/resource/huggingface` (read + additive write) |
| Per-tool caches on Brains | `/data/shil6647/.cache/{uv,pip,torch,triton}` |

`/home` is ~96% full (24 GB free) and `/home/shil6647` is for dotfiles/config
only. `/data` has ~1 TB free. **Never put models, datasets, checkpoints, venvs,
or caches on `/home`.** (Requirement 2.)

## Permissions boundary (requirement 3)

Writes are confined to:
- `/data/shil6647/**` (projects, data, caches) — the primary workspace
- `/home/shil6647/**` (config/dotfiles only)
- `/data/resource/huggingface/**` — **additive only** (new model/dataset
  downloads, which benefit everyone). Never delete or modify others' cached
  entries, and never touch any other user's project dirs or system paths.

`brains.sh` enforces this: every command `cd`s into the project dir under
`/data/shil6647`, and all caches are redirected there.

## The `.brains` config

A small shell-sourceable file at the local repo root, created by
`brains.sh init` and **committed** (no secrets):

```
BRAINS_HOST=brains.oii.ox.ac.uk
BRAINS_USER=shil6647
BRAINS_REMOTE_DIR=/data/shil6647/<project>
```

`brains.sh` walks up from the current directory to find it, so any command works
from anywhere inside the repo. The local repo root is wherever this file lives —
that is how local repos are allowed to be anywhere on the Mac.

## Standard project layout (same on both sides)

```
<project>/
├── .brains              # repo↔Brains mapping (committed)
├── .gitignore           # ignores data/ results/ .venv/ …
├── src/<pkg>/           # importable shared library (used by both sides)
├── pipelines/           # GPU/CPU entry points        → run on Brains
├── analysis/            # notebooks + plotting         → run locally
├── configs/
├── data/                # (gitignored) inputs   — rsync up if needed
└── results/             # (gitignored) outputs  — rsync down for viz; logs/ live here
```

`results/logs/` holds background-job logs and `<job>.meta` provenance stamps.

## Data flow in practice

- **Outputs:** jobs write to `results/` on Brains → `brains.sh sync-down` pulls
  to the local `results/`. `run --sync` does this automatically after a job.
- **Inputs:** put raw data in `data/` on Brains (it stays there; it's big). If
  you generate inputs locally, `brains.sh sync-up data` pushes them.
- **Code:** never via rsync — always git (`brains.sh deploy`). See
  `versioning.md`.
