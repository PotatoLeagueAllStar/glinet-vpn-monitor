#!/bin/sh
# debug-push.sh — Test Grafana Cloud connectivity from the router.
# FOR TESTING ONLY — run this manually on the router, never commit with real credentials.
# Usage: copy to router and run: sh /tmp/debug-push.sh
CONFIG="/etc/vpn-monitor/config"

# Load vars
GRAFANA_METRICS_ID=""
GRAFANA_TOKEN=""
GRAFANA_URL=""

while IFS='=' read -r key val; do
    case "$key" in ''|\#*) continue ;; esac
    key=$(echo "$key" | tr -d ' \t\r')
    val=$(echo "$val" | tr -d ' \t\r')
    case "$key" in
        GRAFANA_METRICS_ID) GRAFANA_METRICS_ID="$val" ;;
        GRAFANA_TOKEN)      GRAFANA_TOKEN="$val" ;;
        GRAFANA_URL)        GRAFANA_URL="$val" ;;
    esac
done < "$CONFIG"

echo "=== Grafana vars ==="
echo "ID:  $GRAFANA_METRICS_ID"
echo "URL: $GRAFANA_URL"
echo "TOK: $(echo "$GRAFANA_TOKEN" | cut -c1-20)..."

echo ""
echo "=== base64 check ==="
which base64 || echo "base64 NOT FOUND"

echo ""
echo "=== Building auth ==="
auth=$(printf '%s:%s' "$GRAFANA_METRICS_ID" "$GRAFANA_TOKEN" | base64 | tr -d '\n')
echo "Auth (first 30 chars): $(echo "$auth" | cut -c1-30)..."

echo ""
echo "=== Push test ==="
NOW=$(date +%s)
TS="${NOW}000000000"
PAYLOAD="wg_tunnel,host=glinet-main,iface=test status=1i ${TS}"
echo "Payload: $PAYLOAD"
echo ""

curl -v -X POST "$GRAFANA_URL" \
    -H "Authorization: Basic $auth" \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary "$PAYLOAD" 2>&1

echo ""
echo "=== Done ==="
