#!/usr/bin/env bash
# Preflight gate to run before ANY Brains operation.
#
# Two checks that are deliberately kept SEPARATE and never conflated:
#   1. Is the Oxford VPN connected?      -> vpn-check.sh (Brains-independent)
#   2. Only if so, is Brains reachable?  -> a single TCP connect to the SSH port
#
# Because step 1 never touches Brains, a Brains-side outage is never misreported
# as "VPN down". The two failure modes get distinct exit codes and messages.
#
# Usage: preflight.sh [host]
# Env:   BRAINS_PORT (default 22), BRAINS_TIMEOUT seconds (default 6)
# Exit:  0 = ONLINE | 1 = VPN down | 2 = VPN up but Brains unreachable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/../config.sh" ]] && source "$HERE/../config.sh"
HOST="${1:-${BRAINS_HOST:-brains.oii.ox.ac.uk}}"
PORT="${BRAINS_PORT:-22}"
TIMEOUT="${BRAINS_TIMEOUT:-6}"

# --- Check 1: VPN state (Brains-independent) ---
vpn_out=$("$HERE/vpn-check.sh"); vpn_rc=$?
echo "$vpn_out"
if [[ $vpn_rc -ne 0 ]]; then
  echo "verdict: OFFLINE — connect the VPN (Cisco Secure Client -> ${BRAINS_VPN_NAME:-vpn.ox.ac.uk}), then retry."
  exit 1
fi

# --- Check 2: Brains reachability (a SEPARATE probe; not a VPN signal) ---
if nc -z -G "$TIMEOUT" "$HOST" "$PORT" 2>/dev/null; then
  echo "brains:  REACHABLE (${HOST}:${PORT})"
  echo "verdict: ONLINE"
  exit 0
else
  echo "brains:  UNREACHABLE (${HOST}:${PORT}) within ${TIMEOUT}s"
  echo "verdict: VPN is UP but Brains is not responding — this is NOT a VPN problem."
  echo "         Likely the server is down/rebooting, SSH is unavailable, or a transient"
  echo "         network issue. Verify with the department or retry shortly."
  exit 2
fi
