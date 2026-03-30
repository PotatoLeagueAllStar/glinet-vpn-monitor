#!/bin/sh
# Redeploys only the config file and runs a live test.
ROUTER="root@<YOUR_ROUTER_IP>"
SSH_KEY="$HOME/.ssh/<YOUR_SSH_KEY>"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ssh_cmd() { ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$@"; }

echo "==> Uploading updated config..."
ssh_cmd "$ROUTER" "cat > /etc/vpn-monitor/config" < "$LOCAL_DIR/config"
ssh_cmd "$ROUTER" "chmod 600 /etc/vpn-monitor/config"

echo "==> Running script to verify..."
ssh_cmd "$ROUTER" "/bin/sh /etc/vpn-monitor/check-vpn.sh && echo 'Script ran OK.'"

echo ""
echo "Done. Check healthchecks.io dashboard."
