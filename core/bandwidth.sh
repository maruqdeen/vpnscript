#!/bin/bash
# VPN-Starter-Kit :: core/bandwidth.sh
# Bandwidth usage reporting via vnstat (lazy-installed on first use, same
# pattern as the other optional services in this repo). Source this file
# for bw_ensure()/bw_day_stats()/bw_month()/_bw_human().
BW_IFACE_FILE="/etc/vpn-script/bandwidth-iface"

# Installs vnstat + registers the primary interface if not already done.
# Prints the interface name to use for the other bw_* functions.
bw_ensure() {
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v vnstat >/dev/null 2>&1; then
    apt-get install -y vnstat >/dev/null 2>&1
    systemctl enable --now vnstat >/dev/null 2>&1
  fi

  local iface
  if [[ -f "$BW_IFACE_FILE" ]]; then
    iface="$(cat "$BW_IFACE_FILE")"
  else
    iface="$(ip route show default | awk '{print $5; exit}')"
    [[ -z "$iface" ]] && iface="eth0"
    echo "$iface" > "$BW_IFACE_FILE"
  fi

  # vnstat needs the interface registered in its database before it has
  # anything to report — harmless no-op if already added.
  vnstat --add -i "$iface" >/dev/null 2>&1 || true

  echo "$iface"
}

# Bytes -> "824.30MB" / "4.12GB" / "1.03TB" style. Byte units use a capital
# B (GB/MB/TB) — lowercase "b" conventionally means bits, and mislabeling
# bytes as bits made the numbers look inflated/wrong at a glance.
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

# Prints "today_bytes yesterday_bytes". Matches vnstat's daily records by
# actual calendar date (not array position [-1]/[-2]) — vnstat's JSON
# ordering isn't something to assume blindly, and a wrong assumption there
# would silently swap or misreport the two figures.
bw_day_stats() {
  local iface="$1"
  local ty tm td yy ym yd
  ty=$(date +%Y); tm=$(date +%-m); td=$(date +%-d)
  yy=$(date -d yesterday +%Y); ym=$(date -d yesterday +%-m); yd=$(date -d yesterday +%-d)
  vnstat -i "$iface" --json d 32 2>/dev/null | jq -r \
    --argjson ty "$ty" --argjson tm "$tm" --argjson td "$td" \
    --argjson yy "$yy" --argjson ym "$ym" --argjson yd "$yd" '
    (.interfaces[0].traffic.day // []) as $days |
    (([$days[] | select(.date.year==$ty and .date.month==$tm and .date.day==$td) | (.rx + .tx)] | add) // 0) as $today |
    (([$days[] | select(.date.year==$yy and .date.month==$ym and .date.day==$yd) | (.rx + .tx)] | add) // 0) as $yesterday |
    "\($today) \($yesterday)"
  ' 2>/dev/null
}

# Total bytes for the current calendar month, matched by year+month rather
# than assuming the last array entry is the current month.
bw_month_bytes() {
  local iface="$1"
  local my mm
  my=$(date +%Y); mm=$(date +%-m)
  vnstat -i "$iface" --json m 12 2>/dev/null | jq -r \
    --argjson my "$my" --argjson mm "$mm" '
    (.interfaces[0].traffic.month // []) as $months |
    (([$months[] | select(.date.year==$my and .date.month==$mm) | (.rx + .tx)] | add) // 0)
  ' 2>/dev/null
}
