#!/bin/sh
# Pause or resume all healthchecks.io tunnel monitors.
# Usage: maintenance.sh start|stop
#   start = pause all checks (suppress alarms during maintenance)
#   stop  = resume all checks (re-activate monitoring)
#
# Requires HCHK_API_KEY in /etc/vpn-monitor/config.
# Get the read-write API key from: healthchecks.io → project → Settings → API Access
#
# Interface names (wgclient1-5) match the GL.iNet WireGuard client naming convention.
# Adjust these names if your router uses different interface names.

CONFIG="/etc/vpn-monitor/config"
. "$CONFIG"

ACTION="$1"
API="https://healthchecks.io/api/v1/checks"

if [ -z "$HCHK_API_KEY" ]; then
  echo "ERROR: HCHK_API_KEY not set in $CONFIG" >&2
  exit 1
fi

if [ "$ACTION" != "start" ] && [ "$ACTION" != "stop" ]; then
  echo "Usage: $0 start|stop" >&2
  exit 1
fi

for iface in wgclient1 wgclient2 wgclient3 wgclient4 wgclient5; do
  eval "uuid=\$$iface"
  eval "name=\${${iface}_name}"
  [ -z "$uuid" ] && continue

  if [ "$ACTION" = "start" ]; then
    curl -s -X POST "$API/$uuid/pause" -H "X-Api-Key: $HCHK_API_KEY" > /dev/null
    echo "  Paused:  ${name:-$iface}"
  else
    curl -s -X POST "$API/$uuid/resume" -H "X-Api-Key: $HCHK_API_KEY" > /dev/null
    echo "  Resumed: ${name:-$iface}"
  fi
done
