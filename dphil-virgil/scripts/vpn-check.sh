#!/usr/bin/env bash
# Is the configured VPN (Cisco Secure Client) connected?
#
# Brains-INDEPENDENT by design: this NEVER contacts Brains. It reads only the
# local Cisco client state and, as a fallback, the local routing table. That
# keeps "the VPN is down" cleanly separate from "Brains is unreachable for some
# other reason" (server down, SSH broken, network issue). Do not determine VPN
# state by trying to reach Brains.
#
# Exit codes:
#   0  VPN connected
#   1  VPN disconnected / still connecting (not ready)
#   2  undetermined (cannot tell from local signals)
set -uo pipefail

_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$_SD/../config.sh" ]] && source "$_SD/../config.sh"

CISCO_VPN="${BRAINS_CISCO_VPN:-/opt/cisco/secureclient/bin/vpn}"
OXFORD_NET="${BRAINS_OXFORD_NET:-163.1}"   # internal IPv4 range your VPN routes (config: BRAINS_OXFORD_NET)

# --- Primary signal: Cisco Secure Client's own reported state ---
if [[ -x "$CISCO_VPN" ]]; then
  out=$("$CISCO_VPN" status 2>/dev/null)
  notice=$(printf '%s\n' "$out" | grep -i ">> notice:" | tail -1 | sed -E 's/.*notice:[[:space:]]*//')
  state=$( printf '%s\n' "$out" | grep -i ">> state:"  | grep -iv Unknown | tail -1 | sed -E 's/.*state:[[:space:]]*//')
  case "$state" in
    [Cc]onnected*)                  echo "vpn: CONNECTED — ${notice:-connected}";              exit 0 ;;
    [Cc]onnecting*|[Rr]econnecting*) echo "vpn: CONNECTING — ${notice:-in progress} (not ready)"; exit 1 ;;
    [Dd]isconnected*)               echo "vpn: DISCONNECTED — ${notice:-not connected}";       exit 1 ;;
  esac
fi

# --- Fallback: routing table (still Brains-independent) ---
# A live VPN installs a route into Oxford's internal range via a utun interface.
# Reading the route table does not touch Brains.
iface=$(netstat -rn -f inet 2>/dev/null \
  | awk -v n="$OXFORD_NET" '$1 ~ ("^" n "\\.") && $NF ~ /^utun/ {print $NF; exit}')
if [[ -n "$iface" ]]; then
  echo "vpn: CONNECTED — route to ${OXFORD_NET}.x via ${iface}"; exit 0
fi

echo "vpn: UNDETERMINED — no Cisco client at ${CISCO_VPN} and no ${OXFORD_NET}.x route via utun"
exit 2
