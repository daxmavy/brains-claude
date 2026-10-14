# Versioning: the laptop is canonical, Virgil is a mirror

**Decision: one git repo per project, on the laptop only.** Virgil holds an
rsynced copy of the working tree and no `.git`, so it needs no GitHub
credentials and can never drift into its own history.

> **Code is mirrored from the laptop. Data and results move by explicit rsync.
> They never mix.**

## Roles

- **Local** is where all code is written and committed. It is the only source of
  truth.
- **Virgil** receives a copy of the working tree before every `run`/`bg`
  (`rsync --delete`, so the copy is exact). Uncommitted changes are included —
  you can try an edit without committing it.
- **Never edit code on Virgil**: the next mirror overwrites it. Put anything
  produced on Virgil under `results/` or `data/`, which the mirror never touches.

## The everyday loop

```
# edit locally …
~/.claude/skills/virgil/scripts/virgil.sh bg train --gpus 1 -- python pipelines/train.py
virgil.sh logs train            # monitor
virgil.sh sync-down             # pull results/ to local for plotting
# … iterate on figures locally, offline if needed
git add -A && git commit -m "…"   # commit as usual
```

`virgil.sh deploy` mirrors the code on its own, without running anything.

## What the mirror skips

Top-level `data/` and `results/`, `.git`, `.venv`, `__pycache__` and
`.ipynb_checkpoints` are excluded from the mirror: never sent, never deleted on
Virgil. Push inputs with `virgil.sh sync-up data` or `virgil.sh put <file>`.

## What is gitignored (never commit)

`init` seeds `.gitignore` with:

```
/data/
/results/
.venv/
__pycache__/
*.pyc
.ipynb_checkpoints/
```

Add model checkpoints, `*.parquet`, large artefacts, etc. as needed. **Data and
results live only on disk + rsync, never in git.**

## Provenance

Every `bg` job writes `results/logs/<job>.meta` stamping the laptop's **git SHA**
and dirty flag at launch:

```
git_sha_local: 3f2a9c1…
git_dirty_local: no
```

So any result traces back to exact code. Commit before a run you want to keep —
`git_dirty_local: yes` means the run used uncommitted changes and is not
reproducible from the SHA alone.
