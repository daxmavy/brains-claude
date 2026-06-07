# config.sh — your settings for the Brains GPU server.
# Set these two to your own, then you're done. Neither is a secret.

export BRAINS_USER="shil6647"        # <-- your Brains (Oxford SSO) username
export BRAINS_CONDA_ENV="daxmavy"    # <-- your conda env on Brains

# Everything else (host, VPN, /data/<username>, the shared HuggingFace cache) is
# already set for Brains — see scripts/brains.sh if you ever need to tweak it.
