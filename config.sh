# config.sh — site configuration for the Brains skill.
#
# EDIT THESE for your own cluster, then you're done. None of these are secrets
# (they're a username, a hostname, and some paths), so this file is safe to keep
# in the repo. Sourced automatically by the scripts in scripts/.
#
# The values below are the author's working example (an Oxford OII GPU box).
# At minimum, change BRAINS_USER and BRAINS_HOST to your own.

# --- SSH target ---------------------------------------------------------------
export BRAINS_USER="shil6647"                       # <-- CHANGE: your SSH username on the server
export BRAINS_HOST="brains.oii.ox.ac.uk"            # <-- CHANGE: your server's hostname

# --- Storage (keep heavy files off a small /home) -----------------------------
export BRAINS_DATA_ROOT="/data/${BRAINS_USER}"      # <-- your large writable dir (repos, data, caches)
export BRAINS_HF_HOME="/data/resource/huggingface"  # <-- shared HuggingFace cache (or set to "$BRAINS_DATA_ROOT/hf")

# --- Python env (conda + uv; see README) --------------------------------------
export BRAINS_CONDA_BASE="/opt/anaconda"            # <-- conda install prefix on the server
export BRAINS_CONDA_ENV="daxmavy"                   # <-- the conda env all remote work runs in

# --- VPN detection (see README "Adapting the VPN check") ----------------------
# These only matter if your server sits behind a VPN. The skill checks the VPN
# WITHOUT contacting the server, so a server outage is never misread as "VPN down".
export BRAINS_CISCO_VPN="/opt/cisco/secureclient/bin/vpn"  # Cisco Secure Client CLI (macOS path)
export BRAINS_OXFORD_NET="163.1"                    # internal IPv4 prefix your VPN routes (fallback signal)
export BRAINS_VPN_NAME="vpn.ox.ac.uk"               # VPN name shown in messages (cosmetic)

# --- GPU sharing policy (optional tuning) -------------------------------------
export BRAINS_GPU_MIN_FREE_MIB="40000"              # a GPU needs >= this much free VRAM to count as "usable"
export BRAINS_GPU_MAX_UTIL="20"                     # ...and <= this % utilisation (lets you share lightly-used GPUs)
