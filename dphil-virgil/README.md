# Virgil skill (DPhil students only)

> **DPhil students only.** This folder is a separate skill for the **Virgil** GPU
> server. MSc students don't have Virgil access: use the Brains skill at the top
> of this repository and ignore this folder. You can install either skill, or
> both. Each one only ever uses its own server.

A [Claude Code](https://docs.claude.com/en/docs/claude-code) **skill** for running GPU work on **Virgil** (Oxford OII, 4× H100 80GB) straight from Claude Code. Ask Claude to *"train a model"* and it recognises the GPU need, connects to Virgil over SSH, copies your code across, runs the job, and pulls the results back to your laptop for analysis.

What it handles for you:

- **Automatic VPN + reachability check** before every remote action. It tells *VPN down* apart from *Virgil down* by reading the VPN client directly, never by probing the server.
- **Strict GPU etiquette.** A GPU is used **only if nobody else has any process on it**. If too few are free, it tells you who's using them. It **never takes all the GPUs without asking you first**.
- Keeps heavy files on **`/VData/<username>`**, reuses the **shared HuggingFace cache**, and runs in **your conda env** with [`uv`](https://github.com/astral-sh/uv) for packages.
- **Your laptop holds the code.** Before every run it mirrors your working tree to Virgil, so a job never runs stale code and Virgil needs no GitHub setup. Results come back by rsync, and every run records the git commit it ran.

## Requirements

- **Claude Code** on your laptop.
- A **Virgil account** (your Oxford SSO username) and the **Oxford VPN** (Cisco Secure Client). Virgil is only reachable on the VPN.
- **Passwordless SSH to Virgil**, i.e. SSH public‑key authentication. One‑time setup:
  ```bash
  ssh-keygen -t ed25519                          # only if you don't already have a key
  ssh-copy-id <username>@virgil.oii.ox.ac.uk     # installs your public key on Virgil
  ssh <username>@virgil.oii.ox.ac.uk 'echo ok'   # must print ok with NO password prompt
  ```
- A **conda env on `/VData`**. Make one once:
  ```bash
  ssh <username>@virgil.oii.ox.ac.uk \
    'source /opt/anaconda/etc/profile.d/conda.sh && conda create -p /VData/<username>/envs/<env> python=3.11 -y'
  ```

## Install

```bash
git clone https://github.com/daxmavy/brains-claude.git ~/brains-claude
ln -s ~/brains-claude/dphil-virgil ~/.claude/skills/virgil
chmod +x ~/brains-claude/dphil-virgil/scripts/*.sh
```

Restart Claude Code if it was already running, so it picks up the skill.

## Configure — just two things

Open [`config.sh`](config.sh) and set your own:

```bash
export VIRGIL_USER="abcd1234"                              # your Oxford SSO username
export VIRGIL_CONDA_ENV="/VData/abcd1234/envs/myenv"       # the conda env you created
```

The host, VPN, your `/VData/<username>` workspace and the shared HuggingFace cache are already set.

## Using it

You normally don't call it, because Claude triggers it whenever a task needs a GPU. By hand it's one CLI:

```bash
scripts/virgil.sh check          # VPN + reachability (auto-runs before every remote command)
scripts/virgil.sh gpus           # who's on which GPU
scripts/virgil.sh init <name>    # set up a project (local .virgil + /VData/<username>/<name>)
scripts/virgil.sh run --gpus 1 -- python pipelines/train.py
scripts/virgil.sh bg train --gpus 1 -- python pipelines/train.py   # detached; survives disconnect
scripts/virgil.sh logs train     # tail it    ·    scripts/virgil.sh stop train
scripts/virgil.sh sync-down      # pull results/ to your laptop for plotting
scripts/virgil.sh install 'torch>=2.4'   # uv install into your conda env
scripts/virgil.sh help           # full command list
```

See [`SKILL.md`](SKILL.md) and [`reference/`](reference/) for the full model.

## Security

No secrets live in this repo. `config.sh` holds just your username and an env path. Authentication uses your SSH keys in `~/.ssh`, which are never committed here.
