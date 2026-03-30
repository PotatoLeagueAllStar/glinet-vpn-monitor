#!/bin/sh
# backup.sh — Back up GL.iNet/OpenWrt config to USB drive + local folder.
# Run from Git Bash: bash backup.sh
# Two copies result: USB on router + local folder.

ROUTER="root@<YOUR_ROUTER_IP>"
SSH_KEY="$HOME/.ssh/<YOUR_SSH_KEY>"
ssh_cmd() { ssh -o StrictHostKeyChecking=accept-new -i "$SSH_KEY" "$@"; }
USB_MOUNT="/tmp/mountd/disk1_part1"        # GL.iNet USB mount point (exfat /dev/sda1)
REMOTE_DIR="$USB_MOUNT/router-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REMOTE_FILE="$REMOTE_DIR/router-backup-$TIMESTAMP.tar.gz"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR/backups"
LOCAL_FILE="$LOCAL_DIR/router-backup-$TIMESTAMP.tar.gz"
KEEP_LAST=14   # rolling window: keep last 14 backups in each location

mkdir -p "$LOCAL_DIR"

# --- One-time router setup: ensure /etc/vpn-monitor is included in backups ---
echo "==> Checking sysupgrade.conf on router..."
ssh_cmd "$ROUTER" "
  if ! grep -q 'vpn-monitor' /etc/sysupgrade.conf 2>/dev/null; then
    echo '/etc/vpn-monitor/' >> /etc/sysupgrade.conf
    echo '  sysupgrade.conf updated.'
  fi
"

# --- Verify USB drive is mounted ---
echo "==> Checking USB drive on router..."
if ! ssh_cmd "$ROUTER" "grep -q '$USB_MOUNT' /proc/mounts"; then
    echo "ERROR: USB drive not found at $USB_MOUNT — is it plugged in?" >&2
    exit 1
fi
ssh_cmd "$ROUTER" "mkdir -p '$REMOTE_DIR'"

# --- Create backup and save to USB ---
echo "==> Creating backup on USB drive..."
ssh_cmd "$ROUTER" "sysupgrade -b '$REMOTE_FILE'"

# Prune old backups on USB (keep last KEEP_LAST)
ssh_cmd "$ROUTER" "ls -t '$REMOTE_DIR'/router-backup-*.tar.gz 2>/dev/null \
    | tail -n +$((KEEP_LAST + 1)) | xargs -r rm -f"

# --- Pull a copy to local machine ---
echo "==> Downloading backup locally..."
ssh_cmd "$ROUTER" "cat '$REMOTE_FILE'" > "$LOCAL_FILE"

# Prune old local backups
ls -t "$LOCAL_DIR"/router-backup-*.tar.gz 2>/dev/null \
    | tail -n +$((KEEP_LAST + 1)) | xargs -r rm -f

echo ""
echo "==> Done."
echo "    USB copy:   $REMOTE_FILE"
echo "    Local copy: $LOCAL_FILE"
echo "    Local backups on disk: $(ls "$LOCAL_DIR"/router-backup-*.tar.gz 2>/dev/null | wc -l)"
