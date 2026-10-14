#!/usr/bin/env bash
# Preflight gate to run before ANY Virgil operation.
#
# Two checks that are deliberately kept SEPARATE and never conflated:
#   1. Is the Oxford VPN connected?      -> vpn-check.sh (Virgil-independent)
#   2. Only if so, is Virgil reachable?  -> a single TCP connect to the SSH port
#
# Because step 1 never touches Virgil, a Virgil-side outage is never misreported
# as "VPN down". The two failure modes get distinct exit codes and messages.
#
# Usage: preflight.sh [host]
# Env:   VIRGIL_PORT (default 22), VIRGIL_TIMEOUT seconds (default 6)
# Exit:  0 = ONLINE | 1 = VPN down | 2 = VPN up but Virgil unreachable
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/../config.sh" ]] && source "$HERE/../config.sh"
HOST="${1:-${VIRGIL_HOST:-virgil.oii.ox.ac.uk}}"
PORT="${VIRGIL_PORT:-22}"
TIMEOUT="${VIRGIL_TIMEOUT:-6}"

# --- Check 1: VPN state (Virgil-independent) ---
vpn_out=$("$HERE/vpn-check.sh"); vpn_rc=$?
echo "$vpn_out"
if [[ $vpn_rc -ne 0 ]]; then
  echo "verdict: OFFLINE — connect the VPN (Cisco Secure Client -> ${VIRGIL_VPN_NAME:-vpn.ox.ac.uk}), then retry."
  exit 1
fi

# --- Check 2: Virgil reachability (a SEPARATE probe; not a VPN signal) ---
if nc -z -G "$TIMEOUT" "$HOST" "$PORT" 2>/dev/null; then
  echo "virgil:  REACHABLE (${HOST}:${PORT})"
  echo "verdict: ONLINE"
  exit 0
else
  echo "virgil:  UNREACHABLE (${HOST}:${PORT}) within ${TIMEOUT}s"
  echo "verdict: VPN is UP but Virgil is not responding — this is NOT a VPN problem."
  echo "         Likely the server is down/rebooting, SSH is unavailable, or a transient"
  echo "         network issue. Verify with the department or retry shortly."
  exit 2
fi
