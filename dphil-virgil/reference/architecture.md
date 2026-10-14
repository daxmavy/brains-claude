# Architecture: local ↔ Virgil

## The split

```
   LOCAL (this Mac)                         VIRGIL (virgil.oii.ox.ac.uk)
   ─────────────────                        ───────────────────────────
   • all visualisation / plotting           • all GPU/CPU-heavy compute
   • notebooks, analysis, writing           • training / inference / sims
   • canonical code (git lives here)        • code mirror (rsynced, never edited)
   • results/ (synced FROM Virgil)          • results/ (written here)
   • data/ subset (optional)               • data/ (full datasets)

            code  ──────── rsync mirror ────────►  code
            data  ◄─────── rsync (virgil.sh) ─────  results
```

Heavy work runs on Virgil; its outputs are pulled to local so analysis and
figures can be iterated **without** a Virgil connection.

## Canonical locations

| What | Where |
|---|---|
| Project dir on Virgil | `/VData/<username>/<project>` (**not** `/home`) |
| Project repo on local | anywhere; linked by the `.virgil` file at its root |
| Big data / outputs / envs / caches on Virgil | under `/VData/<username>` |
| Shared HuggingFace cache | `/VData/resources/huggingface` (read + additive write) |
| Per-tool caches on Virgil | `/VData/<username>/.cache/{uv,pip,torch,triton}` |

`/home/<username>` is for dotfiles/config only and `/scratch` is small. **Never
put models, datasets, checkpoints, envs or caches there.** `/VData` is shared and
often nearly full — check `df -h /VData` before anything large.

## Permissions boundary

Writes are confined to:
- `/VData/<username>/**` (projects, data, envs, caches) — the primary workspace
- `/home/<username>/**` (config/dotfiles only)
- `/VData/resources/huggingface/**` — **additive only** (new model/dataset
  downloads, which benefit everyone). Never delete or modify others' cached
  entries, and never touch any other user's project dirs or system paths.

`virgil.sh` enforces this: every command `cd`s into the project dir under
`/VData/<username>`, and all caches are redirected there.

## The `.virgil` config

A small shell-sourceable file at the local repo root, created by
`virgil.sh init` and **committed** (no secrets):

```
VIRGIL_HOST=virgil.oii.ox.ac.uk
VIRGIL_USER=<username>
VIRGIL_REMOTE_DIR=/VData/<username>/<project>
```

`virgil.sh` walks up from the current directory to find it, so any command works
from anywhere inside the repo. The local repo root is wherever this file lives —
that is how local repos are allowed to be anywhere on the Mac.

## Standard project layout

```
<project>/
├── .virgil              # repo↔Virgil mapping (committed)
├── .gitignore           # ignores data/ results/ .venv/ …
├── src/<pkg>/           # importable shared library (used by both sides)
├── pipelines/           # GPU/CPU entry points        → run on Virgil
├── analysis/            # notebooks + plotting         → run locally
├── configs/
├── data/                # (gitignored) inputs   — rsync up if needed
└── results/             # (gitignored) outputs  — rsync down for viz; logs/ live here
```

`results/logs/` holds background-job logs and `<job>.meta` provenance stamps.

## Data flow in practice

- **Outputs:** jobs write to `results/` on Virgil → `virgil.sh sync-down` pulls
  to the local `results/`. `run --sync` does this automatically after a job.
- **Inputs:** put raw data in `data/` on Virgil (it stays there; it's big). If
  you generate inputs locally, `virgil.sh sync-up data` pushes them.
- **Code:** mirrored from the laptop automatically before every `run`/`bg`
  (or now, with `virgil.sh deploy`). See `versioning.md`.
