# Versioning: one repo, two checkouts

**Decision: one GitHub repo per project, cloned on both local and Brains.** Not
two repos. Two-repo setups duplicate shared code (configs, schemas, model defs),
fragment history, and still need syncing — the wrong trade for solo research.

The core discipline:

> **Code travels by git. Data travels by rsync. They never mix.**

## Roles

- **GitHub is the single source of truth for code.** Both checkouts pull from it.
- **Local** is where you write/edit most code (analysis, viz, and usually the
  compute scripts too) → commit → push.
- **Brains** is a working copy that **pulls before it runs**. Treat its tree as
  "always clean, at a known commit." Avoid editing files there except quick
  fixes, which you immediately commit + push.

This avoids the only real failure mode of one-repo-two-checkouts: divergent
uncommitted edits to the same file on both sides. If you never leave uncommitted
work on Brains, there is nothing to conflict.

## The everyday loop

```
# edit locally …
git add -A && git commit -m "…"
~/.claude/skills/brains/scripts/brains.sh deploy        # push local → pull on Brains
brains.sh bg train --gpus 1 -- python pipelines/train.py
brains.sh logs train            # monitor
brains.sh sync-down             # pull results/ to local for plotting
# … iterate on figures locally, offline if needed
```

`deploy` = `git push` locally, then `git pull --ff-only` on Brains (with
`GIT_TERMINAL_PROMPT=0` so a missing credential fails fast instead of hanging).

### Quick fix made on Brains
```
brains.sh shell      # … edit, then on Brains:
git commit -am "hotfix"; git push
# back on local:
git pull
```

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
results live only on disk + rsync, never in git** — they are too big and change
constantly. Keep small, important config/metadata in git instead.

## Provenance (why one repo wins for reproducibility)

Every `bg` job writes `results/logs/<job>.meta` stamping the **git SHA** and
dirty flag at launch:

```
git_sha: 3f2a9c1…
git_dirty: no
```

So any result traces back to exact code. Keep `git_dirty: no` by committing
before running — then the SHA fully determines the code. (If you see
`git_dirty: yes`, the run used uncommitted changes and is not reproducible from
the SHA alone.)

## Branches

For solo work a single `main` with frequent small commits is simplest. Use a
branch for risky changes; `deploy` pushes the current branch and Brains pulls it
— just make sure Brains is on the same branch (`brains.sh shell` →
`git checkout <branch>`).

## Migrating existing projects

Existing repos are currently cloned in both `/home` and `/data` with `-data`/
`-db`/`-source` siblings. To converge a project onto this standard, per project:
move the `/data/<username>/<project>` clone to be canonical, fold sibling data dirs
into `data/`/`results/`, `init` it, delete the `/home` clone. Do this
deliberately, one project at a time — never bulk-move 320 GB unprompted.
