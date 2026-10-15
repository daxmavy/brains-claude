# Architecture: local ↔ Brains

## The split

```
   LOCAL (this Mac)                         BRAINS (brains.oii.ox.ac.uk)
   ─────────────────                        ───────────────────────────
   • all visualisation / plotting           • all GPU/CPU-heavy compute
   • notebooks, analysis, writing           • training / inference / sims
   • canonical code (git lives here)        • code mirror (rsynced, never edited)
   • results/ (synced FROM Brains)          • results/ (written here)
   • data/ subset (optional)               • data/ (full datasets)

            code  ──────── rsync mirror ────────►  code
            data  ◄─────── rsync (brains.sh) ─────  results
```

Heavy work runs on Brains; its outputs are pulled to local so analysis and
figures can be iterated **without** a Brains connection.

## Canonical locations

| What | Where |
|---|---|
| Project dir on Brains | `/data/<username>/<project>` (**not** `/home`) |
| Project repo on local | anywhere; linked by the `.brains` file at its root |
| Big data / outputs / envs / caches on Brains | under `/data/<username>` |
| Shared HuggingFace cache | `/data/resource/huggingface` (read + additive write) |
| Per-tool caches on Brains | `/data/<username>/.cache/{uv,pip,torch,triton}` |

`/home` is nearly full and `/home/<username>` is for dotfiles/config only. **Never
put models, datasets, checkpoints, venvs or caches there.** Check `df -h /data`
before anything large.

## Permissions boundary

Writes are confined to:
- `/data/<username>/**` (projects, data, envs, caches) — the primary workspace
- `/home/<username>/**` (config/dotfiles only)
- `/data/resource/huggingface/**` — **additive only** (new model/dataset
  downloads, which benefit everyone). Never delete or modify others' cached
  entries, and never touch any other user's project dirs or system paths.

`brains.sh` enforces this: every command `cd`s into the project dir under
`/data/<username>`, and all caches are redirected there.

## The `.brains` config

A small shell-sourceable file at the local repo root, created by
`brains.sh init` and **committed** (no secrets):

```
BRAINS_HOST=brains.oii.ox.ac.uk
BRAINS_USER=<username>
BRAINS_REMOTE_DIR=/data/<username>/<project>
```

`brains.sh` walks up from the current directory to find it, so any command works
from anywhere inside the repo. The local repo root is wherever this file lives —
that is how local repos are allowed to be anywhere on the Mac.

## Standard project layout

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
- **Code:** mirrored from the laptop automatically before every `run`/`bg`
  (or now, with `brains.sh deploy`). See `versioning.md`.
