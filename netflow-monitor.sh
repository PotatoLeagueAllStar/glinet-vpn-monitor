#!/bin/sh
# /etc/vpn-monitor/netflow-monitor.sh
# Sampled flow monitoring: reads nf_conntrack at 1:100, pushes to Grafana Cloud.
# Cron: */5 * * * * /bin/sh /etc/vpn-monitor/netflow-monitor.sh

CONFIG="/etc/vpn-monitor/config"
CONNTRACK="/proc/net/nf_conntrack"
TARGET_SAMPLES=50   # aim for ~50 entries per run regardless of table size
TOP_FLOWS=25

if [ ! -f "$CONFIG" ]; then
    echo "Config file not found: $CONFIG" >&2
    exit 1
fi

# --- Load Grafana Cloud settings ---
GRAFANA_METRICS_ID=""
GRAFANA_TOKEN=""
GRAFANA_URL=""
ROUTER_NAME="glinet"

while IFS='=' read -r key val; do
    case "$key" in ''|\#*) continue ;; esac
    key=$(echo "$key" | tr -d ' \t\r')
    val=$(echo "$val" | tr -d ' \t\r')
    case "$key" in
        GRAFANA_METRICS_ID) GRAFANA_METRICS_ID="$val" ;;
        GRAFANA_TOKEN)      GRAFANA_TOKEN="$val" ;;
        GRAFANA_URL)        GRAFANA_URL="$val" ;;
        ROUTER_NAME)        ROUTER_NAME="$val" ;;
    esac
done < "$CONFIG"

# --- Enable per-connection byte accounting (idempotent) ---
sysctl -w net.netfilter.nf_conntrack_acct=1 > /dev/null 2>&1
ACCT_ENABLED=$(sysctl -n net.netfilter.nf_conntrack_acct 2>/dev/null || echo 0)

# --- Conntrack availability guard ---
if [ ! -f "$CONNTRACK" ]; then
    CONNTRACK="/proc/net/ip_conntrack"
    [ ! -f "$CONNTRACK" ] && exit 0
fi

now=$(date +%s)
timestamp_ns="${now}000000000"

# --- Compute adaptive sample rate: process every Nth entry to get ~TARGET_SAMPLES ---
# If table has fewer than TARGET_SAMPLES entries, rate=1 (process all).
ct_lines=$(wc -l < "$CONNTRACK" 2>/dev/null || echo 0)
SAMPLE_RATE=$(( ct_lines / TARGET_SAMPLES ))
[ "$SAMPLE_RATE" -lt 1 ] && SAMPLE_RATE=1

# --- Parse conntrack, sample 1:SAMPLE_RATE, produce InfluxDB line protocol ---
metrics_batch=$(awk \
    -v rate="$SAMPLE_RATE" \
    -v top="$TOP_FLOWS" \
    -v host="$ROUTER_NAME" \
    -v ts="$timestamp_ns" \
    -v acct="$ACCT_ENABLED" \
'
BEGIN {
    flow_count   = 0
    client_count = 0
    proto_count  = 0
}

# Process only every rate-th line (1:100 sampling)
(NR % rate) != 0 { next }

{
    # Protocol is always field 3 (tcp/udp/icmp/gre/...)
    proto = $3

    # Parse src/dst/dport/bytes positionally (two occurrences each):
    #   First  src= and dst= are the original direction (LAN client → WAN)
    #   Second src= and dst= are the reply direction   (WAN → LAN)
    #   First  bytes= is forward bytes, second bytes= is reply bytes
    src_ip    = ""
    dst_ip    = ""
    dport     = 0
    bytes_fwd = 0
    bytes_rev = 0
    found_src = 0
    found_dst = 0
    found_dport = 0
    bcount    = 0

    for (i = 1; i <= NF; i++) {
        f = $i
        if (f ~ /^src=/) {
            split(f, p, "=")
            if (!found_src) { src_ip = p[2]; found_src = 1 }
        } else if (f ~ /^dst=/) {
            split(f, p, "=")
            if (!found_dst) { dst_ip = p[2]; found_dst = 1 }
        } else if (f ~ /^dport=/ && !found_dport) {
            split(f, p, "=")
            dport = p[2] + 0
            found_dport = 1
        } else if (f ~ /^bytes=/) {
            split(f, p, "=")
            bcount++
            if (bcount == 1) bytes_fwd = p[2] + 0
            if (bcount == 2) bytes_rev = p[2] + 0
        }
    }

    total_bytes = bytes_fwd + bytes_rev

    # --- Store sampled flow record ---
    flow_count++
    f_proto[flow_count]     = proto
    f_src[flow_count]       = src_ip
    f_dst[flow_count]       = dst_ip
    f_dport[flow_count]     = dport
    f_bytes_fwd[flow_count] = bytes_fwd
    f_bytes_rev[flow_count] = bytes_rev
    f_total[flow_count]     = total_bytes

    # --- Per-LAN-client aggregation (all RFC1918 sources) ---
    if (src_ip ~ /^10\./ || src_ip ~ /^192\.168\./ || src_ip ~ /^172\.(1[6-9]|2[0-9]|3[01])\./) {
        if (!(src_ip in c_seen)) {
            clients[++client_count] = src_ip
            c_seen[src_ip] = 1
        }
        c_out[src_ip]   += bytes_fwd
        c_in[src_ip]    += bytes_rev
        c_flows[src_ip]++
    }

    # --- Per-protocol aggregation ---
    if (!(proto in p_seen)) {
        protos[++proto_count] = proto
        p_seen[proto] = 1
    }
    p_bytes[proto] += total_bytes
    p_flows[proto]++
}

END {
    if (flow_count == 0) exit

    # --- Sort: find top N flows by total_bytes (selection sort on index array) ---
    for (i = 1; i <= flow_count; i++) idx[i] = i
    limit = (flow_count < top) ? flow_count : top
    for (i = 1; i <= limit; i++) {
        max_i = i
        for (j = i + 1; j <= flow_count; j++) {
            if (f_total[idx[j]] > f_total[idx[max_i]]) max_i = j
        }
        tmp = idx[i]; idx[i] = idx[max_i]; idx[max_i] = tmp
    }

    # --- Emit netflow_sample (top flows) ---
    for (i = 1; i <= limit; i++) {
        k = idx[i]
        printf "netflow_sample,host=%s,proto=%s,src=%s,dst=%s dport=%di,has_bytes=%di,bytes_fwd=%.0fi,bytes_rev=%.0fi,total_bytes=%.0fi %s\n",
            host, f_proto[k], f_src[k], f_dst[k],
            f_dport[k], acct, f_bytes_fwd[k], f_bytes_rev[k], f_total[k], ts
    }

    # --- Emit netflow_client (per-LAN-client totals) ---
    for (i = 1; i <= client_count; i++) {
        c = clients[i]
        printf "netflow_client,host=%s,client=%s bytes_out=%.0fi,bytes_in=%.0fi,flow_count=%di %s\n",
            host, c, c_out[c], c_in[c], c_flows[c], ts
    }

    # --- Emit netflow_proto (per-protocol totals) ---
    for (i = 1; i <= proto_count; i++) {
        p = protos[i]
        printf "netflow_proto,host=%s,proto=%s total_bytes=%.0fi,flow_count=%di %s\n",
            host, p, p_bytes[p], p_flows[p], ts
    }
}
' "$CONNTRACK")

# --- Push all metrics to Grafana Cloud in one request ---
if [ -n "$GRAFANA_URL" ] && [ -n "$GRAFANA_METRICS_ID" ] && [ -n "$GRAFANA_TOKEN" ] && [ -n "$metrics_batch" ]; then
    auth=$(printf '%s:%s' "$GRAFANA_METRICS_ID" "$GRAFANA_TOKEN" | base64 | tr -d '\n')
    printf '%s' "$metrics_batch" | curl -sS --max-time 15 -X POST "$GRAFANA_URL" \
        -H "Authorization: Basic $auth" \
        -H "Content-Type: text/plain; charset=utf-8" \
        --data-binary @- > /dev/null 2>&1
fi
