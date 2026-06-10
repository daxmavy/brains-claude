# Setup & first-run checklist

This skill needs a few one-time things in place **per user**. An agent installing
or first using the skill should verify each item below and walk the user through
anything missing — don't assume a fresh clone is ready to run. The human-facing
step-by-step (with copy-paste commands) lives in the [README](../README.md); this
file is the checklist plus the bits only the user can do.

## Agent can do autonomously vs. must request from the user

**The agent can do** (once SSH to Brains works): create the conda env, generate the
GitHub SSH key on Brains, write `~/.ssh/config`, set `url.insteadOf`, run
`brains.sh check`, and fill `config.sh` from values the user gives.

**Only the user can do — so request these explicitly:**
- Provide their **Brains username** and **conda-env name** (for `config.sh`).
- Run **`ssh-copy-id <user>@brains.oii.ox.ac.uk`** — needs their Brains password once.
- **Add an SSH public key to GitHub** (web UI) — an agent's `gh` token usually lacks
  the `admin:public_key` scope, so it cannot add keys to the account.
- Run **`gh auth login`** locally if they're not already authenticated (interactive).

## Checklist (verify in order; fix or request what's missing)

| # | Check | Verify with | If missing |
|---|---|---|---|
| 1 | `config.sh` is the user's own | values aren't the committed example (`shil6647` / `daxmavy`) | ask for their Brains username + conda env; write them into `config.sh` |
| 2 | VPN + Brains reachable | `scripts/brains.sh check` → `ONLINE` | ask them to connect the Oxford VPN (Cisco Secure Client) |
| 3 | Passwordless SSH to Brains | `ssh -o BatchMode=yes <user>@brains.oii.ox.ac.uk echo ok` prints `ok` | ask them to run `ssh-copy-id <user>@brains.oii.ox.ac.uk` |
| 4 | Conda env exists on Brains | `ssh <host> 'conda env list' \| grep -w <env>` | offer to create it: `conda create -n <env> python=3.11 -y` |
| 5 | GitHub auth — **local** | `gh auth status` (or `ssh -T git@github.com` → "Hi …") | `gh auth login`, or add an SSH key (`ssh-keygen` → paste `.pub` at github.com/settings/ssh/new) |
| 6 | GitHub auth — **on Brains** | `ssh <host> 'ssh -T git@github.com'` → "Hi …" | set up a key on Brains (README → *GitHub credentials*), then **request the user add the printed public key to GitHub** |

| 7 | *(optional)* Virgil fallback: passwordless SSH | `ssh -o BatchMode=yes <user>@virgil.oii.ox.ac.uk echo ok` | ask them to run `ssh-copy-id <user>@virgil.oii.ox.ac.uk` (password prompt — only they can) |
| 8 | *(optional)* Virgil: conda env exists | `ssh <virgil> 'conda env list' \| grep -w <env>` | offer to create it: `conda create -n <env> python=3.11 -y` |

After **1–4**, the compute side works (`run`/`bg`/`sync-*`/`gpus`/`install`).
Items **5–6** are needed only for the **git code-sync** (`init` cloning, `deploy`,
editing-on-Brains-and-pushing-back). Items **7–8** enable the **Virgil fallback**
(more GPUs when Brains is full); without them the skill still works, Brains-only —
set `VIRGIL_HOST=""` in `config.sh` to silence Virgil entirely. Virgil needs **no
GitHub credentials** (code reaches it by rsync from the laptop).

## Why GitHub auth is needed on BOTH ends

Code moves by git, data by rsync. Git authenticates **independently on each
machine**: your laptop pushes to GitHub; Brains clones/pulls from it (`init`,
`deploy`) and can push back. **Brains has no GitHub credentials by default**, so
without a key on Brains:
- **public** repos can still be *cloned/pulled* on Brains (read is open), but
- **private** repos can't be cloned/pulled on Brains, and
- **no** repo can be *pushed* from Brains.

The one-time fix (a dedicated SSH key on Brains + `url.insteadOf` to route HTTPS
remotes through it) is in the [README](../README.md) under **GitHub credentials**.
The agent can run all of it except the final "paste the public key into GitHub"
step — that one needs the user.
