# config.sh — your settings for the Virgil GPU server.
# Set these two to your own, then you're done. Neither is a secret.

export VIRGIL_USER="your-username"  # <-- your Virgil (Oxford SSO) username
export VIRGIL_CONDA_ENV="your-env"   # <-- path to your conda env on Virgil, e.g. /VData/abcd1234/envs/myenv

# Everything else (host, VPN, /VData/<username>, the shared HuggingFace cache) is
# already set for Virgil — see scripts/virgil.sh if you ever need to tweak it.
