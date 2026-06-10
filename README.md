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
- **GitHub credentials** for the git-based code sync — set up **both on your laptop and on Brains** (Brains has none by default). See [GitHub credentials](#github-credentials-for-the-code-workflow) below.
- *(Optional, for the Virgil fallback)* the same one-time setup on **Virgil** (`virgil.oii.ox.ac.uk`, 4× H100): `ssh-copy-id <username>@virgil.oii.ox.ac.uk` and `ssh <username>@virgil.oii.ox.ac.uk 'conda create -n <your-env> python=3.11 -y'`. No GitHub setup needed on Virgil.

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

## GitHub credentials (for the code workflow)

The skill moves **code by git** and **data by rsync**, so git must authenticate to GitHub on **both** ends — your laptop *and* Brains. Public repos can be *read* on Brains without this, but **pushing from Brains and using private repos require it**.

**On your laptop** — you probably have this already. Check with `gh auth status` (or `ssh -T git@github.com`). If not: run `gh auth login`, or add an SSH key — `ssh-keygen -t ed25519`, then paste `~/.ssh/id_ed25519.pub` at <https://github.com/settings/ssh/new>.

**On Brains** — Brains has **no** GitHub credentials by default. Give it a dedicated SSH key (one-time). SSH in (`ssh <username>@brains.oii.ox.ac.uk`), then run:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/github_ed25519 -N "" -C "$USER@brains-github"
printf '\nHost github.com\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/github_ed25519\n  IdentitiesOnly yes\n' >> ~/.ssh/config && chmod 600 ~/.ssh/config
git config --global url."git@github.com:".insteadOf "https://github.com/"   # route HTTPS remotes through the key
cat ~/.ssh/github_ed25519.pub                                              # copy this line
```

Add the printed key at <https://github.com/settings/ssh/new> (type **Authentication Key**), then verify from Brains:

```bash
ssh -T -o StrictHostKeyChecking=accept-new git@github.com   # expect: Hi <you>! You've successfully authenticated
```

It's an account-level key (works for all your repos), passphraseless so non-interactive git works, and protected by file permissions in `~/.ssh` on Brains — revoke it on GitHub anytime. (Claude can run all of this for you **except** adding the key to GitHub — that step needs you.)

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

## Virgil: more GPUs when Brains is full

The skill also knows **Virgil** (`virgil.oii.ox.ac.uk`, 4× H100 80GB). Priority is always **Brains > Virgil**: jobs run on Brains, and only when Brains can't satisfy a `--gpus N` request does the skill fall back to Virgil. On Virgil the sharing rule is stricter — a GPU is used **only if nobody has any process on it at all**, so you can never block or slow someone else's work there. Code reaches Virgil by rsync from your laptop (no GitHub setup needed there); big files live on `/VData/<username>`; `jobs`/`logs`/`stop`/`sync-down` check both hosts automatically. Force it with `--host virgil`, or disable it with `VIRGIL_HOST=""` in `config.sh`.

## Be a good GPU citizen

Brains is shared. By default the skill treats a GPU as usable only if it has plenty of free memory and low utilisation, and it **will not take all the GPUs at once** without an explicit override. If it can't get what a job needs, it tells you who's using them rather than barging in. On **Virgil** the bar is higher still: only completely-idle GPUs are ever used.

## Security

No secrets live in this repo — `config.sh` is just your username and an env name. Authentication is via your SSH keys in `~/.ssh`, which are never committed here.

## License

[MIT](LICENSE) — adapt freely.
