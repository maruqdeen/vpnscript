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

# Bytes -> "400Mb" / "4Gb" style (whole numbers, matching the requested card).
_bw_human() {
  local bytes="$1"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824) printf "%.0fGb", b/1073741824
    else if (b >= 1048576) printf "%.0fMb", b/1048576
    else if (b >= 1024) printf "%.0fKb", b/1024
    else printf "%.0fb", b
  }'
}

# Prints "today_bytes yesterday_bytes" from a single vnstat call. Falls
# back to 0 for yesterday if vnstat only has one day of history yet
# (fresh install).
bw_day_stats() {
  local iface="$1"
  vnstat -i "$iface" --json d 2 2>/dev/null | jq -r '
    (.interfaces[0].traffic.day) as $d |
    (($d[-1].rx // 0) + ($d[-1].tx // 0)) as $today |
    (if ($d | length) > 1 then (($d[-2].rx // 0) + ($d[-2].tx // 0)) else 0 end) as $yesterday |
    "\($today) \($yesterday)"
  ' 2>/dev/null
}

# Total bytes for the current month.
bw_month_bytes() {
  local iface="$1"
  vnstat -i "$iface" --json m 1 2>/dev/null | jq -r '
    (.interfaces[0].traffic.month[-1]) as $m |
    (($m.rx // 0) + ($m.tx // 0))
  ' 2>/dev/null
}
