# Setup & first-run checklist

This skill needs a few one-time things in place **per user**. An agent installing
or first using the skill should verify each item below and walk the user through
anything missing — don't assume a fresh install is ready to run. The human-facing
step-by-step lives in the [README](../README.md).

## Agent can do autonomously vs. must request from the user

**The agent can do** (once SSH to Brains works): create the conda env, run `brains.sh check`, and fill `config.sh` from values the user gives.
**No GitHub setup is needed on Brains** — code reaches it by rsync.

**Only the user can do — so request these explicitly:**
- Provide their **Oxford username** and **conda-env name** (for `config.sh`).
- Connect the **Oxford VPN** (Cisco Secure Client).
- Run **`ssh-copy-id <user>@brains.oii.ox.ac.uk`** — needs their password once.

## Checklist (verify in order; fix or request what's missing)

| # | Check | Verify with | If missing |
|---|---|---|---|
| 1 | `config.sh` is the user's own | values aren't the committed example (`your-username` / `your-env`) | ask for their username + env name; write them into `config.sh` |
| 2 | VPN + Brains reachable | `scripts/brains.sh check` → `ONLINE` | ask them to connect the Oxford VPN |
| 3 | Passwordless SSH | `ssh -o BatchMode=yes <user>@brains.oii.ox.ac.uk echo ok` prints `ok` | ask them to run `ssh-copy-id <user>@brains.oii.ox.ac.uk` |
| 4 | `/data/<user>` exists and is writable | `ssh <host> 'mkdir -p /data/<user> && touch /data/<user>/.w && rm /data/<user>/.w && echo ok'` | tell the user to ask IT/their supervisor for a `/data` directory |
| 5 | Conda env exists | `ssh <host> 'source /opt/anaconda/etc/profile.d/conda.sh && conda env list' \| grep -w <env>` | create it: `source /opt/anaconda/etc/profile.d/conda.sh && conda create -n <env> python=3.11 -y` |
| 6 | `/data` has room | `ssh <host> 'df -h /data'` | if tight, tell the user before writing anything large |

After these, everything works: `init`/`run`/`bg`/`sync-*`/`gpus`/`install`.
