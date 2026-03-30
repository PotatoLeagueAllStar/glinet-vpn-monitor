#!/bin/sh
# diagnose.sh — Check WireGuard tunnel status on the router.
ROUTER="root@<YOUR_ROUTER_IP>"
SSH_KEY="$HOME/.ssh/<YOUR_SSH_KEY>"
ssh_cmd() { ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$@"; }

ssh_cmd "$ROUTER" '
  echo "=== WireGuard interfaces ==="
  wg show
  echo ""
  echo "=== Raw latest-handshakes per interface ==="
  for iface in wgclient1 wgclient2 wgclient3 wgclient4 wgclient5; do
    echo "--- $iface ---"
    wg show "$iface" latest-handshakes 2>&1
  done
  echo ""
  echo "=== Current time (epoch) ==="
  date +%s
  echo ""
  echo "=== curl test (replace UUID with a value from /etc/vpn-monitor/config) ==="
  # curl -v https://hc-ping.com/YOUR-UUID-HERE 2>&1
'
