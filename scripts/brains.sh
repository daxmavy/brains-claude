#!/usr/bin/env bash
# brains.sh — single parameterized CLI for working with the Brains GPU server.
#
# All Brains interaction goes through here so the invariants hold every time:
#   * preflight VPN/reachability gate before any remote action
#   * remote env is set explicitly (non-interactive SSH does NOT load ~/.bashrc),
#     pointing HF at the shared cache and redirecting package caches off /home
#   * heavy files live under /data/<username>, never the (full) /home
#   * code moves by git; data moves by rsync
#
# Project mapping is read from a `.brains` file at the repo root (see `init`).
# Run `brains.sh help` for the command list.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load site config (username, host, paths, conda env, VPN) if present — see config.sh.
[[ -f "$SCRIPT_DIR/../config.sh" ]] && source "$SCRIPT_DIR/../config.sh"

# ---- Defaults: fallbacks if config.sh is absent (overridable by env / .brains) ----
: "${BRAINS_HOST:=brains.oii.ox.ac.uk}"
: "${BRAINS_USER:=shil6647}"
: "${BRAINS_DATA_ROOT:=/data/$BRAINS_USER}"
: "${BRAINS_HF_HOME:=/data/resource/huggingface}"
: "${BRAINS_CONDA_BASE:=/opt/anaconda}"   # conda installation on Brains
: "${BRAINS_CONDA_ENV:=daxmavy}"          # the env ALL remote work runs in (deps via uv)
# A GPU is "usable" (shareable) if it has >= this much free memory AND <= this
# utilisation — lets us co-locate on lightly-used GPUs. Tunable via env.
: "${BRAINS_GPU_MIN_FREE_MIB:=40000}"
: "${BRAINS_GPU_MAX_UTIL:=20}"
SSH_OPTS=(-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new)

err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---- Per-project config: walk up from cwd to find `.brains` ----
BRAINS_PROJECT_ROOT=""
BRAINS_REMOTE_DIR=""
load_config() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/.brains" ]]; then
      BRAINS_PROJECT_ROOT="$dir"
      # shellcheck disable=SC1091
      source "$dir/.brains"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}
need_config() {
  load_config || die "No .brains file found above $PWD. Run 'brains.sh init <project-name>' in your repo root first."
  [[ -n "$BRAINS_REMOTE_DIR" ]] || die ".brains found at $BRAINS_PROJECT_ROOT but BRAINS_REMOTE_DIR is unset."
}

# ---- Canonical remote environment preamble ----
# Emitted into EVERY remote command. Non-interactive SSH skips ~/.bashrc, so we
# set this ourselves: shared HF cache (req: check shared cache) + caches moved
# off the 96%-full /home onto /data (req: heavy files on /data).
remote_env() {
  cat <<EOF
export HF_HOME='${BRAINS_HF_HOME}'
export HF_HUB_CACHE='${BRAINS_HF_HOME}/hub'
export HF_DATASETS_CACHE='${BRAINS_HF_HOME}/datasets'
export UV_CACHE_DIR='${BRAINS_DATA_ROOT}/.cache/uv'
export PIP_CACHE_DIR='${BRAINS_DATA_ROOT}/.cache/pip'
export TORCH_HOME='${BRAINS_DATA_ROOT}/.cache/torch'
export TRITON_CACHE_DIR='${BRAINS_DATA_ROOT}/.cache/triton'
export XDG_CACHE_HOME='${BRAINS_DATA_ROOT}/.cache'
export CUDA_DEVICE_ORDER=PCI_BUS_ID
mkdir -p "\$UV_CACHE_DIR" "\$PIP_CACHE_DIR" "\$TORCH_HOME" "\$TRITON_CACHE_DIR" 2>/dev/null || true
# Activate the conda env (conda is NOT loaded in non-interactive SSH). Deps are
# managed with uv *inside* this env (uv auto-targets the active conda env).
source '${BRAINS_CONDA_BASE}/etc/profile.d/conda.sh' 2>/dev/null \\
  || { echo 'brains: conda.sh not found at ${BRAINS_CONDA_BASE}' >&2; exit 1; }
conda activate '${BRAINS_CONDA_ENV}' \\
  || { echo 'brains: could not activate conda env ${BRAINS_CONDA_ENV}' >&2; exit 1; }
EOF
}

b64()      { printf '%s' "$1" | base64 | tr -d '\n'; }            # local encode (mac)
ssh_raw()  { ssh "${SSH_OPTS[@]}" "${BRAINS_USER}@${BRAINS_HOST}" "$@"; }

# Prefer a modern rsync (e.g. Homebrew) over macOS's bundled 2.6.9 if present.
rsync_bin() {
  local c
  for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync rsync; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  echo rsync
}
# Flags kept compatible with rsync 2.6.9 (no --info=*, no -h).
do_rsync() { "$(rsync_bin)" -az --partial --stats -e "ssh ${SSH_OPTS[*]}" "$@"; }

# Single-quote args for safe embedding in a remote command string.
shquote() { local p out=""; for p in "$@"; do p=${p//\'/\'\\\'\'}; out+=" '$p'"; done; printf '%s' "$out"; }

# Resolve a remote path: absolute stays as-is; relative is taken under the
# project's remote dir (needs a .brains).
resolve_remote() {
  if [[ "$1" == /* ]]; then printf '%s' "$1"; else need_config; printf '%s' "$BRAINS_REMOTE_DIR/$1"; fi
}

# Run an arbitrary script string on Brains, robustly (base64 avoids all quoting
# pain). Stdout/stderr stream straight back.
ssh_script() {  # ssh_script <script-text>
  local enc; enc="$(b64 "$1")"
  ssh_raw "echo '$enc' | base64 -d | bash"
}

# Automatic connectivity gate. Runs the preflight ONCE per invocation: silent when
# online, and on failure it prints the VPN-vs-Brains diagnosis and aborts with the
# preflight's exit code (1 = VPN down, 2 = Brains unreachable). Every remote command
# is wrapped in gated() at dispatch, so this happens for free — no manual `check`.
_BRAINS_PREFLIGHT_OK=0
preflight_gate() {
  [[ "$_BRAINS_PREFLIGHT_OK" == 1 ]] && return 0
  local out rc
  out="$("$SCRIPT_DIR/preflight.sh" "$BRAINS_HOST" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then printf '%s\n' "$out" >&2; exit "$rc"; fi
  _BRAINS_PREFLIGHT_OK=1
}
gated() { preflight_gate; "$@"; }   # auto-preflight, then run the command

# Run the GPU report / policy checker (gpu_report.py) ON Brains. Extra args are
# forwarded to it (e.g. --need 2 / --want 2,3 / --allow-all). nvidia-smi on the
# Brains node only sees Brains' GPUs — Virgil is never touched.
run_gpu_report() {
  ssh "${SSH_OPTS[@]}" "${BRAINS_USER}@${BRAINS_HOST}" \
    "python3 - --min-free-mib $BRAINS_GPU_MIN_FREE_MIB --max-util $BRAINS_GPU_MAX_UTIL $*" \
    < "$SCRIPT_DIR/gpu_report.py"
}

# Resolve a GPU request to a concrete CUDA_VISIBLE_DEVICES list, enforcing the
# availability check AND the "never occupy ALL GPUs without permission" policy.
# The full occupancy report (who is using what) is shown to the user on stderr;
# only the chosen list is returned on stdout. A non-zero return means the request
# was refused — the report above explains why (insufficient / needs-permission).
resolve_gpus() {  # resolve_gpus <need|""> <want|""> <allow:0|1>
  local need="$1" want="$2" allow="$3" pyargs="" report rc
  [[ -n "$need" ]] && pyargs="--need $need"
  [[ -n "$want" ]] && pyargs="--want $want"
  [[ "$allow" == 1 ]] && pyargs="$pyargs --allow-all"
  report="$(run_gpu_report $pyargs 2>&1)"; rc=$?
  printf '%s\n' "$report" >&2
  [[ $rc -eq 0 ]] || return $rc
  printf '%s' "$(printf '%s\n' "$report" | sed -n 's/^SELECT=//p' | tail -1)"
}

# Build the inner runner: env + cd + optional GPU pin + the user command.
build_runner() {  # build_runner <subdir> <gpu-or-empty> <user-cmd>
  local subdir="$1" gpu="$2" cmd="$3" wd="$BRAINS_REMOTE_DIR"
  [[ -n "$subdir" ]] && wd="$BRAINS_REMOTE_DIR/$subdir"
  printf '#!/usr/bin/env bash\nset -o pipefail\n'   # not -u: conda/user scripts aren't -u clean
  remote_env
  [[ -n "$gpu" ]] && printf "export CUDA_VISIBLE_DEVICES='%s'\n" "$gpu"
  printf "cd '%s' || { echo 'remote dir missing: %s' >&2; exit 1; }\n" "$wd" "$wd"
  printf '%s\n' "$cmd"
}

# =====================================================================
# Subcommands
# =====================================================================

cmd_check() { exec "$SCRIPT_DIR/preflight.sh" "$BRAINS_HOST"; }
cmd_vpn()   { exec "$SCRIPT_DIR/vpn-check.sh"; }

cmd_config() {
  load_config || die "No .brains file found above $PWD."
  cat <<EOF
project root (local): $BRAINS_PROJECT_ROOT
remote host:          ${BRAINS_USER}@${BRAINS_HOST}
remote dir:           $BRAINS_REMOTE_DIR
shared HF cache:      $BRAINS_HF_HOME
EOF
}

cmd_gpus() {  # full free/busy + per-user occupancy report
  run_gpu_report
}

cmd_gpu_check() {  # gpu-check <n> [--allow-all-gpus] — can I get n GPUs now?
  [[ $# -ge 1 ]] || die "gpu-check: usage: gpu-check <num-gpus> [--allow-all-gpus]"
  local need="$1"; shift
  local allow=""
  [[ "${1:-}" == "--allow-all-gpus" ]] && allow="--allow-all"
  run_gpu_report --need "$need" $allow
}

cmd_hf() {  # hf-ls [pattern]
  local pat="${1:-}"
  info "Shared HF hub cache ($BRAINS_HF_HOME/hub)${pat:+ matching '$pat'}:"
  if [[ -n "$pat" ]]; then
    ssh_raw "ls '$BRAINS_HF_HOME/hub' 2>/dev/null | grep -i -- '$pat' || echo '(no match — not yet cached)'"
  else
    ssh_raw "ls '$BRAINS_HF_HOME/hub' 2>/dev/null | grep -E '^(models|datasets)--' | head -60"
  fi
}

cmd_install() {  # install <pkgs...> — uv pip install into the conda env
  [[ $# -ge 1 ]] || die "install: usage: install <packages...>  (into conda env ${BRAINS_CONDA_ENV} via uv)"
  info "uv pip install into conda env ${BRAINS_CONDA_ENV}: $*"
  ssh_script "$(remote_env)
uv pip install$(shquote "$@")"
}

cmd_run() {  # run [--dir D] [--gpus N | --gpu LIST] [--allow-all-gpus] [--sync] -- <cmd...>
  need_config
  local subdir="" need="" want="" allow=0 sync=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)            subdir="$2"; shift 2 ;;
      --gpus)           need="$2";   shift 2 ;;
      --gpu)            want="$2";   shift 2 ;;
      --allow-all-gpus) allow=1;     shift ;;
      --sync)           sync=1;      shift ;;
      --)               shift; break ;;
      *) die "run: unknown option '$1' (did you forget '--' before the command?)" ;;
    esac
  done
  [[ $# -gt 0 ]] || die "run: no command given (usage: run [opts] -- <cmd>)"
  local gpu=""
  if [[ -n "$need" || -n "$want" ]]; then
    gpu="$(resolve_gpus "$need" "$want" "$allow")" || return $?   # refused -> report shown above
    info "using GPU(s): ${gpu:-none}"
  fi
  ssh_script "$(build_runner "$subdir" "$gpu" "$*")"
  local rc=$?
  [[ $sync -eq 1 ]] && cmd_sync_down results
  return $rc
}

cmd_bg() {  # bg <name> [--dir D] [--gpu N|auto] -- <cmd...>
  need_config
  [[ $# -gt 0 && "$1" != --* ]] || die "bg: first arg must be a job name"
  local name="$1"; shift
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "bg: job name must be [A-Za-z0-9_-]"
  local subdir="" need="" want="" allow=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)            subdir="$2"; shift 2 ;;
      --gpus)           need="$2";   shift 2 ;;
      --gpu)            want="$2";   shift 2 ;;
      --allow-all-gpus) allow=1;     shift ;;
      --)               shift; break ;;
      *) die "bg: unknown option '$1'" ;;
    esac
  done
  [[ $# -gt 0 ]] || die "bg: no command given"
  local gpu=""
  if [[ -n "$need" || -n "$want" ]]; then
    gpu="$(resolve_gpus "$need" "$want" "$allow")" || return $?   # refused -> report shown above
    info "using GPU(s): ${gpu:-none}"
  fi

  local logd="$BRAINS_REMOTE_DIR/results/logs"
  local runner_enc; runner_enc="$(b64 "$(build_runner "$subdir" "$gpu" "$*")")"
  # Outer launcher: write runner, stamp provenance, start detached (tmux > setsid).
  local launcher
  launcher=$(cat <<EOF
set -uo pipefail
LOGD='$logd'; NAME='$name'
mkdir -p "\$LOGD"
echo '$runner_enc' | base64 -d > "\$LOGD/\$NAME.run.sh"
{ echo "name: \$NAME";
  echo "started_utc: \$(date -u +%FT%TZ)";
  echo "git_sha: \$(git -C '$BRAINS_REMOTE_DIR' rev-parse HEAD 2>/dev/null || echo NA)";
  echo "git_dirty: \$(test -n "\$(git -C '$BRAINS_REMOTE_DIR' status --porcelain 2>/dev/null)" && echo yes || echo no)";
  echo "gpu: ${gpu:-default}"; } > "\$LOGD/\$NAME.meta"
if command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s "brains_\$NAME" "bash '\$LOGD/\$NAME.run.sh' > '\$LOGD/\$NAME.log' 2>&1"
  echo "started: tmux session brains_\$NAME"
else
  setsid bash -c "bash '\$LOGD/\$NAME.run.sh' > '\$LOGD/\$NAME.log' 2>&1" &
  echo \$! > "\$LOGD/\$NAME.pid"; echo "started: pid \$(cat "\$LOGD/\$NAME.pid")"
fi
echo "log: $logd/\$NAME.log"
EOF
)
  ssh_script "$launcher"
  info ""
  info "Monitor:  brains.sh logs $name      Stop: brains.sh stop $name      Pull: brains.sh sync-down"
}

cmd_jobs() {
  info "Running Brains jobs (tmux sessions named brains_*):"
  ssh_raw "tmux ls 2>/dev/null | grep '^brains_' || echo '(none running)'"
}

cmd_logs() {  # logs <name> [n]
  need_config
  [[ $# -ge 1 ]] || die "logs: usage: logs <name> [lines]"
  local name="$1" n="${2:-60}"
  ssh_raw "tail -n '$n' '$BRAINS_REMOTE_DIR/results/logs/$name.log' 2>/dev/null || echo 'no log for $name'"
}

cmd_stop() {  # stop <name>
  need_config
  [[ $# -ge 1 ]] || die "stop: usage: stop <name>"
  local name="$1" logd="$BRAINS_REMOTE_DIR/results/logs"
  ssh_script "
    if tmux has-session -t 'brains_$name' 2>/dev/null; then
      tmux kill-session -t 'brains_$name'; echo 'killed tmux session brains_$name'
    elif [[ -f '$logd/$name.pid' ]]; then
      kill -TERM -- -\$(cat '$logd/$name.pid') 2>/dev/null && echo 'killed pid group' || echo 'pid not running'
    else echo 'no such job: $name'; fi"
}

cmd_sync_down() {  # sync-down [subdir=results]
  need_config
  local sub="${1:-results}"
  local remote="${BRAINS_USER}@${BRAINS_HOST}:${BRAINS_REMOTE_DIR}/${sub}/"
  local local_dir="${BRAINS_PROJECT_ROOT}/${sub}/"
  mkdir -p "$local_dir"
  info "sync-down: $remote  ->  $local_dir"
  do_rsync "$remote" "$local_dir"
}

cmd_sync_up() {  # sync-up [subdir=data]
  need_config
  local sub="${1:-data}"
  info "NOTE: code should travel by git (use 'deploy'); sync-up is for data only."
  local local_dir="${BRAINS_PROJECT_ROOT}/${sub}/"
  local remote="${BRAINS_USER}@${BRAINS_HOST}:${BRAINS_REMOTE_DIR}/${sub}/"
  [[ -d "$local_dir" ]] || die "sync-up: local $local_dir does not exist"
  ssh_raw "mkdir -p '$BRAINS_REMOTE_DIR/$sub'"
  info "sync-up:   $local_dir  ->  $remote"
  do_rsync "$local_dir" "$remote"
}

cmd_get() {  # get <remote> [local] — fetch a single file/dir from Brains
  [[ $# -ge 1 ]] || die "get: usage: get <remote-path> [local-path]  (remote: relative to project, or absolute)"
  local rp lp
  rp="$(resolve_remote "$1")"
  lp="${2:-./$(basename "$1")}"
  mkdir -p "$(dirname "$lp")"
  info "get: ${BRAINS_USER}@${BRAINS_HOST}:$rp  ->  $lp"
  do_rsync "${BRAINS_USER}@${BRAINS_HOST}:$rp" "$lp"
}

cmd_put() {  # put <local> [remote] — push a single file/dir to Brains (writes only under your dirs)
  [[ $# -ge 1 ]] || die "put: usage: put <local-path> [remote-path]  (remote: relative to project, or absolute)"
  [[ -e "$1" ]] || die "put: local path '$1' does not exist"
  local lp="$1" rp
  if [[ $# -ge 2 ]]; then rp="$(resolve_remote "$2")"; else need_config; rp="$BRAINS_REMOTE_DIR/$(basename "$lp")"; fi
  case "$rp" in
    "$BRAINS_DATA_ROOT"/*|/home/"$BRAINS_USER"/*) ;;
    *) die "put: refusing to write outside your dirs ($BRAINS_DATA_ROOT or /home/$BRAINS_USER): $rp" ;;
  esac
  ssh_raw "mkdir -p '$(dirname "$rp")'"
  info "put: $lp  ->  ${BRAINS_USER}@${BRAINS_HOST}:$rp"
  do_rsync "$lp" "${BRAINS_USER}@${BRAINS_HOST}:$rp"
}

cmd_deploy() {  # push local commits, then pull them on Brains
  need_config
  info "git push (local)…"
  git -C "$BRAINS_PROJECT_ROOT" push || die "local git push failed"
  info "git pull (Brains)…"
  ssh_script "export GIT_TERMINAL_PROMPT=0; cd '$BRAINS_REMOTE_DIR' && git pull --ff-only"
}

cmd_shell() {  # interactive login shell in the project dir
  load_config || true
  local cd_to="${BRAINS_REMOTE_DIR:-\$HOME}"
  exec ssh "${SSH_OPTS[@]}" -t "${BRAINS_USER}@${BRAINS_HOST}" "cd '$cd_to' 2>/dev/null; exec bash -l"
}

cmd_init() {  # init <project-name>
  [[ $# -ge 1 ]] || die "init: usage: init <project-name> (run from your local repo root)"
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || die "init: name must be [A-Za-z0-9_.-]"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "init: not inside a git repo. Create/clone your repo first, then run init from its root."
  local remote_dir="${BRAINS_DATA_ROOT}/${name}"

  # 1) local .brains
  if [[ -f "$root/.brains" ]]; then
    info ".brains already exists — leaving it untouched."
  else
    cat > "$root/.brains" <<EOF
# Brains project mapping (safe to commit — no secrets).
BRAINS_HOST=${BRAINS_HOST}
BRAINS_USER=${BRAINS_USER}
BRAINS_REMOTE_DIR=${remote_dir}
EOF
    info "wrote $root/.brains  (remote dir: $remote_dir)"
  fi

  # 2) gitignore for the big/transient dirs
  local gi="$root/.gitignore"
  touch "$gi"
  local entry
  for entry in "/data/" "/results/" ".venv/" "__pycache__/" "*.pyc" ".ipynb_checkpoints/"; do
    grep -qxF "$entry" "$gi" 2>/dev/null || echo "$entry" >> "$gi"
  done
  info "ensured .gitignore covers data/, results/, .venv/ …"

  # 3) local scaffold
  mkdir -p "$root/data" "$root/results" "$root/analysis" "$root/pipelines"
  [[ -f "$root/results/.gitkeep" ]] || : > "$root/results/.gitkeep"

  # 4) remote: preflight, make dirs + caches, clone if a remote exists
  local url; url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  ssh_script "
    set -uo pipefail
    mkdir -p '$remote_dir' '${BRAINS_DATA_ROOT}/.cache'
    if [[ -n '$url' ]]; then
      if [[ -d '$remote_dir/.git' ]]; then echo 'remote repo already present'
      else
        export GIT_TERMINAL_PROMPT=0
        git clone '$url' '$remote_dir' && echo 'cloned $url -> $remote_dir' \
          || echo 'WARN: clone failed (check GitHub credentials on Brains); dir created empty'
      fi
    else
      echo 'no origin remote locally — created $remote_dir but did not clone'
    fi
    echo 'remote ready: $remote_dir'"
  info ""
  info "Done. Commit .brains + .gitignore, then use: brains.sh deploy / run / bg / sync-down."
}

cmd_help() {
  cat <<'EOF'
brains.sh — interact with the Brains GPU server (direct-exec model)

Connectivity (no .brains needed):
  check                 explicit VPN + reachability preflight (auto-runs before every remote cmd)
  vpn                   VPN state only (Brains-independent; reads the Cisco client)
  gpus                  per-GPU free/busy + who occupies each + per-user totals
  gpu-check <n>         can I get n free GPUs now? names who's blocking if not
  hf-ls [pattern]       list the shared HuggingFace cache (CHECK before downloading)
  install <pkgs...>     uv pip install into the <your-env> conda env (deps live there)

Per-project (needs a .brains file at the repo root):
  init <name>           scaffold project: write .brains/.gitignore, make /data/<username>/<name>, clone repo
  config                show the resolved local<->remote mapping
  run [opts] -- <cmd>   run on Brains (foreground). opts: --dir D  --gpus N | --gpu LIST  --allow-all-gpus  --sync
  bg <name> [opts] -- <cmd>   run detached (tmux), survives disconnect; same --gpus/--gpu/--allow-all-gpus opts
  jobs                  list running background jobs
  logs <name> [n]       tail a background job's log
  stop <name>           stop a background job
  sync-down [subdir]    rsync remote -> local (default: results/)  ← pull data for local viz
  sync-up   [subdir]    rsync local -> remote (default: data/)     ← inputs only; code goes via git
  get <remote> [local]  fetch one file/dir from Brains (remote rel. to project, or absolute)
  put <local> [remote]  push one file/dir to Brains (only writes under your dirs)
  deploy                git push (local) then git pull (Brains)    ← the code-sync path
  shell                 interactive login shell in the project dir

Preflight: every remote command auto-checks the VPN + reachability first — silent
when online, and aborts with a VPN-vs-Brains diagnosis when not. No manual `check`.
Env: every remote command runs in the `<your-env>` conda env (install deps with uv,
which targets it); HF shared cache + /data caches + CUDA_DEVICE_ORDER=PCI_BUS_ID
(so CUDA indices match nvidia-smi) are all set for you automatically.
GPU policy: request GPUs with --gpus N (or --gpu LIST). The request is refused if
fewer than N are free (you get a per-user occupancy report), or if it would take
ALL GPUs — that needs --allow-all-gpus, only after the user explicitly approves.
Brains GPUs only; never Virgil. Heavy outputs live under /data/<username>/<name>;
models reuse the shared HF cache; all visualisation happens locally.
EOF
}

# =====================================================================
main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    # Local / diagnostic — no connectivity needed, so no auto-preflight.
    check)              cmd_check "$@" ;;
    vpn)                cmd_vpn "$@" ;;
    config)             cmd_config "$@" ;;
    help|-h|--help)     cmd_help ;;
    # Remote commands — gated() auto-runs the VPN/reachability preflight first.
    gpus|gpu)           gated cmd_gpus "$@" ;;
    gpu-check|gpucheck) gated cmd_gpu_check "$@" ;;
    hf-ls|hf)           gated cmd_hf "$@" ;;
    install|pip)        gated cmd_install "$@" ;;
    init)               gated cmd_init "$@" ;;
    run)                gated cmd_run "$@" ;;
    bg)                 gated cmd_bg "$@" ;;
    jobs)               gated cmd_jobs "$@" ;;
    logs|tail)          gated cmd_logs "$@" ;;
    stop)               gated cmd_stop "$@" ;;
    sync-down|down)     gated cmd_sync_down "$@" ;;
    sync-up|up)         gated cmd_sync_up "$@" ;;
    get)                gated cmd_get "$@" ;;
    put)                gated cmd_put "$@" ;;
    deploy)             gated cmd_deploy "$@" ;;
    shell|ssh)          gated cmd_shell "$@" ;;
    *) err "unknown command: $sub"; cmd_help; exit 2 ;;
  esac
}
main "$@"
