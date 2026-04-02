#!/bin/sh
# Run this from your local machine (Git Bash or any POSIX shell).
# Uses SSH only (no scp/sftp) — compatible with OpenWrt.
# Uses SSH key — no password prompts.

ROUTER="root@<YOUR_ROUTER_IP>"
SSH_KEY="$HOME/.ssh/<YOUR_SSH_KEY>"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"
ssh_cmd() { ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$@"; }

echo "==> Creating /etc/vpn-monitor on router..."
ssh_cmd "$ROUTER" "mkdir -p /etc/vpn-monitor /tmp/vpn-monitor"

echo "==> Uploading config..."
ssh_cmd "$ROUTER" "cat > /etc/vpn-monitor/config" < "$LOCAL_DIR/config"
ssh_cmd "$ROUTER" "chmod 600 /etc/vpn-monitor/config"

echo "==> Uploading check-vpn.sh..."
ssh_cmd "$ROUTER" "cat > /etc/vpn-monitor/check-vpn.sh" < "$LOCAL_DIR/check-vpn.sh"

echo "==> Uploading netflow-monitor.sh..."
ssh_cmd "$ROUTER" "cat > /etc/vpn-monitor/netflow-monitor.sh" < "$LOCAL_DIR/netflow-monitor.sh"

echo "==> Enabling nf_conntrack_acct and registering netflow cron..."
ssh_cmd "$ROUTER" '
  chmod +x /etc/vpn-monitor/netflow-monitor.sh

  # Persist nf_conntrack_acct across reboots
  if [ ! -f /etc/sysctl.d/10-conntrack-acct.conf ]; then
    echo "net.netfilter.nf_conntrack_acct=1" > /etc/sysctl.d/10-conntrack-acct.conf
    echo "  Created /etc/sysctl.d/10-conntrack-acct.conf"
  fi
  sysctl -w net.netfilter.nf_conntrack_acct=1 > /dev/null 2>&1 && echo "  nf_conntrack_acct enabled."

  # Add netflow cron job if not already present
  if ! crontab -l 2>/dev/null | grep -q "netflow-monitor.sh"; then
    (crontab -l 2>/dev/null; echo "*/5 * * * * /bin/sh /etc/vpn-monitor/netflow-monitor.sh") | crontab -
    echo "  Netflow cron job added."
  else
    echo "  Netflow cron job already present."
  fi

  echo ""
  echo "==> Running netflow-monitor.sh once to verify..."
  /bin/sh /etc/vpn-monitor/netflow-monitor.sh && echo "  Netflow script ran OK."
'

echo "==> Setting permissions, updating cron, and running test..."
ssh_cmd "$ROUTER" '
  chmod +x /etc/vpn-monitor/check-vpn.sh

  # Add cron job if not already present
  if ! crontab -l 2>/dev/null | grep -q "check-vpn.sh"; then
    (crontab -l 2>/dev/null; echo "* * * * * /bin/sh /etc/vpn-monitor/check-vpn.sh") | crontab -
    echo "  Cron job added."
  else
    echo "  Cron job already present."
  fi

  echo ""
  echo "==> Running script once to verify..."
  /bin/sh /etc/vpn-monitor/check-vpn.sh && echo "  Script ran OK."

  echo ""
  echo "==> Current crontab:"
  crontab -l
'

echo "==> Uploading maintenance.sh..."
ssh_cmd "$ROUTER" "cat > /etc/vpn-monitor/maintenance.sh" < "$LOCAL_DIR/maintenance.sh"
ssh_cmd "$ROUTER" "chmod +x /etc/vpn-monitor/maintenance.sh"

echo "==> Installing boot-time resume script..."
ssh_cmd "$ROUTER" 'cat > /etc/init.d/vpn-monitor-resume' << 'INITEOF'
#!/bin/sh /etc/rc.common
START=99
start() {
    sleep 30
    # Skip resume if within scheduled maintenance window (Mon/Thu 2:55-3:15 AM).
    # The 3:15 AM cron will handle the resume; acting now would cancel the pause early.
    DOW=$(date +%u)  # 1=Mon, 4=Thu (ISO weekday)
    HOUR=$(date +%H | sed 's/^0//'); MIN=$(date +%M | sed 's/^0//')
    TIME=$(( ${HOUR:-0} * 60 + ${MIN:-0} ))
    if { [ "$DOW" = "1" ] || [ "$DOW" = "4" ]; } && [ "$TIME" -ge 175 ] && [ "$TIME" -lt 195 ]; then
        exit 0
    fi
    /bin/sh /etc/vpn-monitor/maintenance.sh stop
}
INITEOF
ssh_cmd "$ROUTER" '
  chmod +x /etc/init.d/vpn-monitor-resume
  /etc/init.d/vpn-monitor-resume enable
  echo "  Boot-time resume script installed and enabled."
'

echo "==> Registering maintenance cron jobs (Mon+Thu 2:55 AM pause, 3:15 AM resume)..."
ssh_cmd "$ROUTER" '
  if ! crontab -l 2>/dev/null | grep -q "maintenance.sh start"; then
    (crontab -l 2>/dev/null; echo "55 2 * * 1,4 /bin/sh /etc/vpn-monitor/maintenance.sh start") | crontab -
    echo "  Pause cron added."
  else
    echo "  Pause cron already present."
  fi
  if ! crontab -l 2>/dev/null | grep -q "maintenance.sh stop"; then
    (crontab -l 2>/dev/null; echo "15 3 * * 1,4 /bin/sh /etc/vpn-monitor/maintenance.sh stop") | crontab -
    echo "  Resume cron added."
  else
    echo "  Resume cron already present."
  fi
'

echo ""
echo "Done. Check healthchecks.io — active tunnels should show green shortly."
