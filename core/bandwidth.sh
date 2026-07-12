#!/bin/bash
# VPN-Starter-Kit :: core/bandwidth.sh
# Account-attributable bandwidth reporting: sums real per-account usage
# across SSH, Xray (VMess/VLESS/Trojan), and WireGuard, rather than
# interface-wide vnstat totals. vnstat counted ALL server traffic (SSH
# admin access, apt/package installs, background system chatter), so a
# fresh box with zero VPN accounts still showed dozens of MB "used"
# before any client had ever connected. Source this file for
# bw_ssh_bytes()/bw_wireguard_bytes()/bw_xray_bytes()/_bw_human().
#
# Each source's counter is a running cumulative total (since account
# creation for SSH, since the WireGuard tunnel last came up, since Xray's
# Stats API was enabled) — there's no calendar-day breakdown, unlike the
# old vnstat-based Today/Yesterday/Month.

SSH_LIMITS_JSON="/etc/vpn-script/ssh-limits.json"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_API_SERVER="127.0.0.1:10085"
WG_IFACE="wg0"

# Bytes -> "824.30MB" / "4.12GB" / "1.03TB" style. Byte units use a capital
# B (GB/MB/TB) — lowercase "b" conventionally means bits.
_bw_human() {
  local bytes="$1"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1099511627776) printf "%.2fTB", b/1099511627776
    else if (b >= 1073741824) printf "%.2fGB", b/1073741824
    else if (b >= 1048576) printf "%.2fMB", b/1048576
    else if (b >= 1024) printf "%.2fKB", b/1024
    else printf "%dB", b
  }'
}

# Sum of bw_used_bytes across every tracked SSH/SlowDNS account (0 if the
# file doesn't exist yet — nothing created, nothing tracked).
bw_ssh_bytes() {
  local v
  v="$(jq '[.[].bw_used_bytes] | add // 0' "$SSH_LIMITS_JSON" 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Sum of rx+tx across every WireGuard peer, straight from the kernel via
# `wg show <iface> dump` — native counters, no extra instrumentation needed.
bw_wireguard_bytes() {
  local v
  command -v wg >/dev/null 2>&1 || { echo 0; return; }
  v="$(wg show "$WG_IFACE" dump 2>/dev/null | tail -n +2 | awk -F'\t' '{rx+=$6; tx+=$7} END{print (rx+tx)+0}')"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

# Sum of uplink+downlink across every VMess/VLESS/Trojan client via Xray's
# Stats API. Returns 0 (not an error) if the API isn't enabled yet — see
# install/migrate-xray-stats-api.sh.
bw_xray_bytes() {
  local v
  command -v xray >/dev/null 2>&1 || { echo 0; return; }
  jq -e '.api.services // [] | index("StatsService")' "$XRAY_CONFIG" >/dev/null 2>&1 || { echo 0; return; }
  v="$(xray api statsquery --server="$XRAY_API_SERVER" -pattern "user>>>" 2>/dev/null \
    | jq '[.stat[]?.value | tonumber] | add // 0' 2>/dev/null)"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}
