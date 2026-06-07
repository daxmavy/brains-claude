# brains-claude

A [Claude Code](https://docs.claude.com/en/docs/claude-code) **skill** that lets Claude run GPU/CPU‑heavy work on a remote server (here nicknamed **"Brains"**) autonomously — so when you ask it to *"train a model"*, it recognises the GPU need, connects to your server, sets the job up, runs it, and pulls the results back for local analysis. You never have to tell it "use the server."

It packages a single parameterised CLI (`scripts/brains.sh`) plus the conventions that make remote compute safe and repeatable:

- **Automatic VPN / reachability preflight** before every remote action — and it tells *VPN‑down* apart from *server‑unreachable* (it reads the VPN client directly, never by probing the server).
- **GPU scheduling policy** — checks who's using which GPUs, reports per‑user occupancy when it can't get enough, picks the freest, and **never grabs every GPU without explicit permission**.
- **Keeps heavy files off `/home`** (onto a big `/data`‑style disk), **reuses a shared HuggingFace cache**, and runs everything in a known **conda env with `uv`** for dependencies.
- **Clear local↔remote split:** code travels by **git**, data by **rsync**; all visualisation happens locally on synced results.
- Single‑file transfers (`get`/`put`), background jobs that survive disconnects (`tmux`), and run **provenance** (every job stamps the git SHA).

> ⚠️ **This was built and tested for one specific setup** (an Oxford OII box: macOS client → Cisco Secure Client VPN → direct SSH execution, no Slurm; conda + a shared HF cache; A100/L40S GPUs). It's designed to be adapted — see **[Adapting it to your setup](#adapting-it-to-your-setup)**. Most of it is generic; the VPN check and the "direct execution" model are the parts most likely to need changes.

---

## Requirements

- **Claude Code** installed on your machine.
- A **remote server you can SSH into** that has NVIDIA GPUs (`nvidia-smi`), `git`, `rsync`, `tmux`, and `conda` + [`uv`](https://github.com/astral-sh/uv).
- **Passwordless SSH** to that server — i.e. **SSH public‑key (key‑based) authentication**. This is essential: the skill runs non‑interactive SSH (`BatchMode`), so any password prompt makes it fail. See [Set up passwordless SSH](#set-up-passwordless-ssh).
- macOS client with **Cisco Secure Client** *if* your server sits behind that VPN (otherwise adapt the VPN check — see below).

## Install

Clone (or symlink) this repo into your Claude Code skills directory as `brains`:

```bash
git clone https://github.com/daxmavy/brains-claude.git ~/.claude/skills/brains
chmod +x ~/.claude/skills/brains/scripts/*.sh
```

Claude Code discovers the skill from `SKILL.md`. Restart/refresh Claude Code if it was already running.

## Configure

**Everything site‑specific lives in [`config.sh`](config.sh).** Open it and change the values to match your cluster — at minimum your **username** and **host**:

| Variable | What it is |
|---|---|
| `BRAINS_USER` | **Your SSH username on the server** (the most important change) |
| `BRAINS_HOST` | Your server's hostname |
| `BRAINS_DATA_ROOT` | A large writable dir for repos/data/caches (keep heavy files off `/home`) |
| `BRAINS_HF_HOME` | Shared HuggingFace cache to reuse (or point at your own under `/data`) |
| `BRAINS_CONDA_BASE` | conda install prefix on the server (e.g. `/opt/anaconda`) |
| `BRAINS_CONDA_ENV` | the conda env all remote work runs in |
| `BRAINS_CISCO_VPN` | path to the Cisco Secure Client `vpn` CLI (VPN users) |
| `BRAINS_OXFORD_NET` | internal IPv4 prefix your VPN routes (fallback VPN signal) |
| `BRAINS_VPN_NAME` | VPN name shown in messages (cosmetic) |
| `BRAINS_GPU_MIN_FREE_MIB` / `BRAINS_GPU_MAX_UTIL` | when a GPU counts as "usable" for sharing |

Then **edit the description in [`SKILL.md`](SKILL.md)'s frontmatter** so it names *your* server — that's what tells Claude when to reach for the skill. (You can also rename the skill folder if you don't want it called `brains`.)

### Set up passwordless SSH

If `ssh <user>@<host>` still asks for a password, set up key auth once:

```bash
ssh-keygen -t ed25519            # if you don't already have a key (~/.ssh/id_ed25519)
ssh-copy-id <user>@<host>        # installs your public key on the server
ssh <user>@<host> 'echo ok'      # must print "ok" with NO password prompt
```

(The author already had this configured — it's easy to forget it's a prerequisite.)

## Adapting it to your setup

- **Different VPN, or no VPN.** The VPN check lives in [`scripts/vpn-check.sh`](scripts/vpn-check.sh) and assumes macOS + Cisco Secure Client (it parses `vpn status`, with a routing‑table fallback). To adapt: replace the detection with your VPN client's status command. **If you have no VPN**, make `vpn-check.sh` always exit `0` — `preflight.sh` will then just do the TCP reachability check. The design rule worth keeping: *determine VPN state without contacting the server*, so an outage is never misreported as "VPN down".
- **Slurm instead of direct execution.** This skill runs jobs **directly** on the node (SSH + `tmux`). If your cluster requires Slurm, adapt the `run`/`bg` commands in `scripts/brains.sh` to `srun`/`sbatch` and the GPU policy to allocations.
- **Mixed‑GPU nodes (gotcha).** The env preamble sets `CUDA_DEVICE_ORDER=PCI_BUS_ID` so CUDA's device indices match `nvidia-smi`'s. Without it, CUDA's default order can differ and `CUDA_VISIBLE_DEVICES=0` may land on a *different* physical GPU than you selected. Keep this if your node mixes GPU types.
- **No conda.** Point `BRAINS_CONDA_*` at your setup, or edit the activation in `remote_env()` in `scripts/brains.sh` to your environment manager.

## Usage

Once installed and configured, you normally don't call it directly — Claude triggers it when a task needs the server. The CLI is also usable by hand:

```bash
scripts/brains.sh check          # VPN + reachability (auto-runs before every remote command)
scripts/brains.sh gpus           # who's on which GPU, memory, and the freest one
scripts/brains.sh init <name>    # set up a project (local .brains + remote /data dir + clone)
scripts/brains.sh run  --gpus 1 -- python pipelines/train.py
scripts/brains.sh bg   train --gpus 1 -- python pipelines/train.py   # detached; survives disconnect
scripts/brains.sh logs train     # tail it    ·    scripts/brains.sh stop train
scripts/brains.sh sync-down      # pull results/ to local for plotting
scripts/brains.sh install 'torch>=2.4' transformers   # uv install into the conda env
scripts/brains.sh help           # full command list
```

See [`SKILL.md`](SKILL.md) and [`reference/`](reference/) for the full model: [architecture](reference/architecture.md), [versioning](reference/versioning.md), and the [remote environment](reference/remote-environment.md).

## Repository layout

```
SKILL.md                     # the skill manifest Claude reads (edit its description for your server)
config.sh                    # ← your site config (username, host, paths, conda env, VPN)
scripts/
  brains.sh                  # the single parameterised CLI
  preflight.sh, vpn-check.sh # the connectivity gate (VPN-independent of the server)
  gpu_report.py              # GPU occupancy + sharing-policy checker (runs on the server)
reference/                   # architecture, versioning, remote-environment docs
```

## Security

No secrets are stored in this repo. `config.sh` holds only a username, a hostname, and paths — none are sensitive. Authentication is via your SSH keys in `~/.ssh` (never committed here). Per‑project `.brains` files (created by `init`) likewise contain no secrets.

## License

[MIT](LICENSE) — adapt freely.
