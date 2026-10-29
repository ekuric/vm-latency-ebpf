#!/usr/bin/env bash
# Synthetic guest RTT (ICMP). Not eBPF — complements host net-path probes.
# Env:
#   GUEST_IPS     comma-separated IPs from VMI status
#   PING_COUNT    packets per IP (default 20)
#   PING_DEADLINE seconds (default 30)

set -euo pipefail

GUEST_IPS="${GUEST_IPS:-}"
PING_COUNT="${PING_COUNT:-20}"
PING_DEADLINE="${PING_DEADLINE:-30}"
OUT="${1:-/tmp/vm-latency-work/guest_ping.txt}"

mkdir -p "$(dirname "$OUT")"
: >"$OUT"

echo "=== [4b] Synthetic guest RTT (ICMP ping) ===" | tee -a "$OUT"

if [[ -z "$GUEST_IPS" ]]; then
  echo "no GUEST_IPS set; skip ping" | tee -a "$OUT"
  exit 0
fi

if ! command -v ping >/dev/null 2>&1; then
  echo "ping binary missing; skip" | tee -a "$OUT"
  exit 0
fi

IFS=',' read -ra IPS <<<"$GUEST_IPS"
for ip in "${IPS[@]}"; do
  ip="${ip// /}"
  [[ -n "$ip" ]] || continue
  # Skip IPv6 link-local noise unless explicitly alone
  echo "--- ping ${ip} count=${PING_COUNT} ---" | tee -a "$OUT"
  # -n numeric, -c count, -w deadline (Linux)
  if ping -n -c "$PING_COUNT" -w "$PING_DEADLINE" "$ip" >>"$OUT" 2>&1; then
    :
  else
    echo "ping failed or partial for ${ip} (guest firewall / OVN reachability / no hostNetwork?)" | tee -a "$OUT"
  fi
  echo | tee -a "$OUT"
done

# Parse rtt min/avg/max from ping summary lines
python3 - "$OUT" <<'PY' || true
import re, sys
text = open(sys.argv[1]).read()
# rtt min/avg/max/mdev = 0.123/0.456/0.789/0.012 ms
pat = re.compile(r"rtt min/avg/max(?:/mdev)? = ([0-9.]+)/([0-9.]+)/([0-9.]+)")
print("\n--- ping summary ---")
found = False
for m in pat.finditer(text):
    found = True
    mn, avg, mx = m.group(1), m.group(2), m.group(3)
    print(f"[4b] Guest ICMP RTT: min={mn}ms avg={avg}ms max={mx}ms")
if not found:
    print("[4b] Guest ICMP RTT: (no successful ping stats — check reachability)")
PY
