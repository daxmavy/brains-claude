# brains-claude

A [Claude Code](https://docs.claude.com/en/docs/claude-code) **skill** for running GPU work on the **Brains** server (Oxford OII) straight from Claude Code — built for students on the course. Ask Claude to *"train a model"* and it recognises the GPU need, connects to Brains over SSH, sets the job up, runs it, and pulls the results back to your laptop for analysis. You never have to tell it "use Brains."

What it handles for you:

- **Automatic VPN + reachability check** before every remote action — and it tells *VPN‑down* apart from *Brains‑down* (it reads the VPN client directly, never by probing the server).
- **GPU etiquette on a shared box** — checks who's on which GPU, reports per‑user usage when it can't get enough, picks the freest, and **never grabs all the GPUs without asking you first**.
- Keeps heavy files on **`/data`** (not the tiny `/home`), reuses the **shared HuggingFace cache**, and runs in **your conda env** with [`uv`](https://github.com/astral-sh/uv) for packages.
- **Code travels by git, data by rsync**, with all plotting done locally on synced results. Background jobs survive disconnects; every run records the git commit it ran.

## Requirements

- **Claude Code** on your laptop.
- A **Brains account** (your Oxford SSO username) and the **Oxford VPN** (Cisco Secure Client) — Brains is only reachable on the VPN.
- **Passwordless SSH to Brains** — i.e. **SSH public‑key (key‑based) authentication**. The skill runs non‑interactive SSH, so any password prompt makes it fail. One‑time setup:
  ```bash
  ssh-keygen -t ed25519                          # only if you don't already have a key
  ssh-copy-id <username>@brains.oii.ox.ac.uk     # installs your public key on Brains
  ssh <username>@brains.oii.ox.ac.uk 'echo ok'   # must print ok with NO password prompt
  ```
- A **conda env on Brains** to run in — make one once:
  ```bash
  ssh <username>@brains.oii.ox.ac.uk 'conda create -n <your-env> python=3.11 -y'
  ```

## Install

```bash
git clone https://github.com/daxmavy/brains-claude.git ~/.claude/skills/brains
chmod +x ~/.claude/skills/brains/scripts/*.sh
```

Restart Claude Code if it was already running, so it picks up the skill.

## Configure — just two things

Open [`config.sh`](config.sh) and set your own:

```bash
export BRAINS_USER="abcd1234"        # your Brains (Oxford SSO) username
export BRAINS_CONDA_ENV="your-env"   # the conda env you created on Brains
```

That's everything — the host, VPN, your `/data/<username>` workspace, and the shared HuggingFace cache are already set for Brains.

## Using it

You normally don't call it — Claude triggers it whenever a task needs Brains. By hand it's one CLI:

```bash
scripts/brains.sh check          # VPN + reachability (auto-runs before every remote command)
scripts/brains.sh gpus           # who's on which GPU + the freest one
scripts/brains.sh init <name>    # set up a project (local .brains + /data/<username>/<name>)
scripts/brains.sh run --gpus 1 -- python pipelines/train.py
scripts/brains.sh bg train --gpus 1 -- python pipelines/train.py   # detached; survives disconnect
scripts/brains.sh logs train     # tail it    ·    scripts/brains.sh stop train
scripts/brains.sh sync-down      # pull results/ to your laptop for plotting
scripts/brains.sh install 'torch>=2.4'   # uv install into your conda env
scripts/brains.sh help           # full command list
```

See [`SKILL.md`](SKILL.md) and [`reference/`](reference/) for the full model: [architecture](reference/architecture.md), [versioning](reference/versioning.md), and the [remote environment](reference/remote-environment.md). Those docs use `<username>`/`<your-env>` as placeholders — the scripts use your real values from `config.sh`.

## Be a good GPU citizen

Brains is shared. By default the skill treats a GPU as usable only if it has plenty of free memory and low utilisation, and it **will not take all the GPUs at once** without an explicit override. If it can't get what a job needs, it tells you who's using them rather than barging in.

## Security

No secrets live in this repo — `config.sh` is just your username and an env name. Authentication is via your SSH keys in `~/.ssh`, which are never committed here.

## License

[MIT](LICENSE) — adapt freely.
