#!/bin/sh
# /etc/vpn-monitor/check-vpn.sh
# Checks each WireGuard tunnel listed in /etc/vpn-monitor/config.
# Pings healthchecks.io with success or failure for each tunnel.
# Pushes bandwidth, latency, jitter, and packet-loss metrics to Grafana Cloud.

CONFIG="/etc/vpn-monitor/config"
STALE_SECONDS=200
STATE_DIR="/tmp/vpn-monitor"
PING_COUNT=3

if [ ! -f "$CONFIG" ]; then
    echo "Config file not found: $CONFIG" >&2
    exit 1
fi

# --- Load Grafana Cloud settings (first pass) ---
GRAFANA_METRICS_ID=""
GRAFANA_TOKEN=""
GRAFANA_URL=""
ROUTER_NAME="glinet"

WAN_IFACE="eth1"

while IFS='=' read -r key val; do
    case "$key" in ''|\#*) continue ;; esac
    key=$(echo "$key" | tr -d ' \t\r')
    val=$(echo "$val" | tr -d ' \t\r')
    case "$key" in
        GRAFANA_METRICS_ID) GRAFANA_METRICS_ID="$val" ;;
        GRAFANA_TOKEN)      GRAFANA_TOKEN="$val" ;;
        GRAFANA_URL)        GRAFANA_URL="$val" ;;
        ROUTER_NAME)        ROUTER_NAME="$val" ;;
        WAN_IFACE)          WAN_IFACE="$val" ;;
    esac
done < "$CONFIG"

mkdir -p "$STATE_DIR"

now=$(date +%s)
timestamp_ns="${now}000000000"
metrics_batch=""

# --- Main tunnel loop (second pass) ---
while IFS='=' read -r iface uuid; do
    # Skip blank lines, comments, and known config-only keys
    case "$iface" in
        ''|\#*|GRAFANA_METRICS_ID|GRAFANA_TOKEN|GRAFANA_URL|ROUTER_NAME|WAN_IFACE|*_name) continue ;;
    esac

    iface=$(echo "$iface" | tr -d ' \t\r')
    uuid=$(echo "$uuid" | tr -d ' \t\r')
    tunnel_name=$(grep "^${iface}_name=" "$CONFIG" | cut -d= -f2 | tr -d ' \t\r')
    [ -z "$tunnel_name" ] && tunnel_name="$iface"

    # --- Handshake status ---
    latest=$(wg show "$iface" latest-handshakes 2>/dev/null \
        | awk '{print $2}' \
        | sort -n \
        | tail -1)

    age_seconds=0
    if [ -z "$latest" ] || [ "$latest" = "0" ]; then
        status="fail"
        status_int=0
    else
        age_seconds=$((now - latest))
        if [ "$age_seconds" -gt "$STALE_SECONDS" ]; then
            status="fail"
            status_int=0
        else
            status="ok"
            status_int=1
        fi
    fi

    # --- Bandwidth (interface-level counters — accurate even with hardware acceleration) ---
    rx_total=$(cat /sys/class/net/${iface}/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_total=$(cat /sys/class/net/${iface}/statistics/tx_bytes 2>/dev/null || echo 0)

    state_file="$STATE_DIR/${iface}_bytes"
    rx_rate=0
    tx_rate=0
    if [ -f "$state_file" ]; then
        prev_rx=$(awk '{print $1}' "$state_file")
        prev_tx=$(awk '{print $2}' "$state_file")
        prev_time=$(awk '{print $3}' "$state_file")
        elapsed=$((now - prev_time))
        if [ "$elapsed" -gt 0 ] && [ "$rx_total" -ge "$prev_rx" ] && [ "$tx_total" -ge "$prev_tx" ]; then
            rx_rate=$(( (rx_total - prev_rx) / elapsed ))
            tx_rate=$(( (tx_total - prev_tx) / elapsed ))
        fi
    fi
    printf '%s %s %s\n' "$rx_total" "$tx_total" "$now" > "$state_file"

    # --- Latency / Jitter / Packet Loss (ping peer endpoint) ---
    endpoint_ip=$(wg show "$iface" endpoints 2>/dev/null \
        | awk '{print $2}' | cut -d: -f1 | head -1)
    latency_ms="0.000"
    jitter_ms="0.000"
    packet_loss_pct=100

    if [ -n "$endpoint_ip" ]; then
        ping_out=$(ping -c "$PING_COUNT" -W 2 -q "$endpoint_ip" 2>/dev/null)
        pl=$(echo "$ping_out" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+')
        [ -n "$pl" ] && packet_loss_pct="$pl"

        # Busybox format: "round-trip min/avg/max = X.X/Y.Y/Z.Z ms"
        rtt_vals=$(echo "$ping_out" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+')
        if [ -n "$rtt_vals" ]; then
            min_rtt=$(echo "$rtt_vals" | cut -d/ -f1)
            avg_rtt=$(echo "$rtt_vals" | cut -d/ -f2)
            max_rtt=$(echo "$rtt_vals" | cut -d/ -f3)
            latency_ms="$avg_rtt"
            jitter_ms=$(awk "BEGIN{printf \"%.3f\", ($max_rtt - $min_rtt) / 2}")
        fi
    fi

    # --- Healthchecks.io ping ---
    if [ "$status" = "fail" ]; then
        curl -fsS --max-time 10 --retry 2 "https://hc-ping.com/${uuid}/fail" > /dev/null 2>&1
    else
        curl -fsS --max-time 10 --retry 2 "https://hc-ping.com/${uuid}" > /dev/null 2>&1
    fi

    # --- Accumulate Grafana metric line (InfluxDB line protocol) ---
    metric_line="wg_tunnel,host=${ROUTER_NAME},iface=${iface},name=${tunnel_name} status=${status_int}i,handshake_age_sec=${age_seconds}i,latency_ms=${latency_ms},jitter_ms=${jitter_ms},packet_loss_pct=${packet_loss_pct}i,rx_bytes_total=${rx_total}i,tx_bytes_total=${tx_total}i,rx_bytes_per_sec=${rx_rate}i,tx_bytes_per_sec=${tx_rate}i ${timestamp_ns}"
    metrics_batch="${metrics_batch}${metric_line}
"

done < "$CONFIG"

# --- Router system metrics ---

# CPU usage: two /proc/stat samples 1 second apart to get real delta
cpu_pct="0.000"
read -r cpu1 </proc/stat
sleep 1
read -r cpu2 </proc/stat
now=$(date +%s)
timestamp_ns="${now}000000000"

cpu1_total=$(echo "$cpu1" | awk '{print $2+$3+$4+$5+$6+$7+$8}')
cpu1_idle=$(echo "$cpu1"  | awk '{print $5}')
cpu2_total=$(echo "$cpu2" | awk '{print $2+$3+$4+$5+$6+$7+$8}')
cpu2_idle=$(echo "$cpu2"  | awk '{print $5}')
cpu_total_delta=$((cpu2_total - cpu1_total))
cpu_idle_delta=$((cpu2_idle - cpu1_idle))
if [ "$cpu_total_delta" -gt 0 ]; then
    cpu_pct=$(awk "BEGIN{printf \"%.3f\", 100 * ($cpu_total_delta - $cpu_idle_delta) / $cpu_total_delta}")
fi

# Load average
load1=$(awk '{print $1}' /proc/loadavg)
load5=$(awk '{print $2}' /proc/loadavg)
load15=$(awk '{print $3}' /proc/loadavg)

# Memory
mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_used_pct="0.000"
if [ -n "$mem_total" ] && [ "$mem_total" -gt 0 ]; then
    mem_used_pct=$(awk "BEGIN{printf \"%.3f\", 100 * ($mem_total - $mem_avail) / $mem_total}")
fi

# Uptime (integer seconds)
uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime)

# Active connections (conntrack table)
active_connections=0
if [ -f /proc/net/nf_conntrack ]; then
    active_connections=$(wc -l < /proc/net/nf_conntrack)
elif [ -f /proc/net/ip_conntrack ]; then
    active_connections=$(wc -l < /proc/net/ip_conntrack)
fi

# WAN bandwidth — same rate-calculation pattern as WireGuard interfaces
wan_rx_total=$(cat /sys/class/net/${WAN_IFACE}/statistics/rx_bytes 2>/dev/null || echo 0)
wan_tx_total=$(cat /sys/class/net/${WAN_IFACE}/statistics/tx_bytes 2>/dev/null || echo 0)
wan_state_file="$STATE_DIR/wan_bytes"
wan_rx_bps=0
wan_tx_bps=0
if [ -f "$wan_state_file" ]; then
    prev_wan_rx=$(awk '{print $1}' "$wan_state_file")
    prev_wan_tx=$(awk '{print $2}' "$wan_state_file")
    prev_wan_time=$(awk '{print $3}' "$wan_state_file")
    wan_elapsed=$((now - prev_wan_time))
    if [ "$wan_elapsed" -gt 0 ] && [ "$wan_rx_total" -ge "$prev_wan_rx" ] && [ "$wan_tx_total" -ge "$prev_wan_tx" ]; then
        wan_rx_bps=$(( (wan_rx_total - prev_wan_rx) / wan_elapsed ))
        wan_tx_bps=$(( (wan_tx_total - prev_wan_tx) / wan_elapsed ))
    fi
fi
printf '%s %s %s\n' "$wan_rx_total" "$wan_tx_total" "$now" > "$wan_state_file"

# Storage usage
flash_used_pct="0.000"
flash_df=$(df /overlay 2>/dev/null | awk 'NR==2{print $3, $2}')
if [ -n "$flash_df" ]; then
    flash_used=$(echo "$flash_df" | awk '{print $1}')
    flash_total=$(echo "$flash_df" | awk '{print $2}')
    [ "$flash_total" -gt 0 ] && flash_used_pct=$(awk "BEGIN{printf \"%.3f\", 100 * $flash_used / $flash_total}")
fi

usb_used_pct="0.000"
usb_df=$(df /tmp/mountd/disk1_part1 2>/dev/null | awk 'NR==2{print $3, $2}')
if [ -n "$usb_df" ]; then
    usb_used=$(echo "$usb_df" | awk '{print $1}')
    usb_total=$(echo "$usb_df" | awk '{print $2}')
    [ "$usb_total" -gt 0 ] && usb_used_pct=$(awk "BEGIN{printf \"%.3f\", 100 * $usb_used / $usb_total}")
fi

sys_line="router_system,host=${ROUTER_NAME} cpu_pct=${cpu_pct},mem_used_pct=${mem_used_pct},load1=${load1},load5=${load5},load15=${load15},uptime_sec=${uptime_sec}i,active_connections=${active_connections}i,wan_rx_bps=${wan_rx_bps}i,wan_tx_bps=${wan_tx_bps}i,flash_used_pct=${flash_used_pct},usb_used_pct=${usb_used_pct} ${timestamp_ns}"
metrics_batch="${metrics_batch}${sys_line}
"

# --- Push all metrics to Grafana Cloud in one request ---
if [ -n "$GRAFANA_URL" ] && [ -n "$GRAFANA_METRICS_ID" ] && [ -n "$GRAFANA_TOKEN" ]; then
    auth=$(printf '%s:%s' "$GRAFANA_METRICS_ID" "$GRAFANA_TOKEN" | base64 | tr -d '\n')
    printf '%s' "$metrics_batch" | curl -sS --max-time 15 -X POST "$GRAFANA_URL" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: text/plain; charset=utf-8" \
        --data-binary @- > /dev/null 2>&1
fi
