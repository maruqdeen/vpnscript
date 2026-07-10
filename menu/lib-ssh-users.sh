#!/bin/bash
# VPN-Starter-Kit :: menu/lib-ssh-users.sh
# Shared helpers for listing SSH-WS + SlowDNS system accounts.
# Source this file; it is not meant to be executed directly.

# usernames of every VPN-managed SSH/SlowDNS account (created by
# add-ssh-user.sh / trial-ssh-user.sh: UID >= 1000, shell /bin/false or nologin)
ssh_user_list() {
  awk -F: '$3>=1000 && $3<60000 && ($7=="/bin/false" || $7=="/usr/sbin/nologin") {print $1}' \
    /etc/passwd | sort
}

# "Mon DD, YYYY" (or "never") for a given username, straight from chage.
ssh_user_expiry() {
  local exp
  exp="$(chage -l "$1" 2>/dev/null | awk -F': ' '/^Account expires/{print $2}' | sed 's/^ *//')"
  echo "${exp:-never}"
}

# UNLOCKED (green) unless the password is administratively locked
# (passwd -S shows L) or the expiry date has passed.
ssh_user_status() {
  local name="$1" exp="$2" pstate
  local G=$'\e[0;32m' R=$'\e[0;31m' X=$'\e[0m'

  pstate="$(passwd -S "$name" 2>/dev/null | awk '{print $2}')"
  if [[ "$pstate" == "L" ]]; then
    printf "%sLOCKED%s" "$R" "$X"; return
  fi
  if [[ "$exp" != "never" ]]; then
    local exp_epoch today_epoch
    exp_epoch="$(date -d "$exp" +%s 2>/dev/null || echo 0)"
    today_epoch="$(date +%s)"
    if (( exp_epoch > 0 && exp_epoch < today_epoch )); then
      printf "%sLOCKED%s" "$R" "$X"; return
    fi
  fi
  printf "%sUNLOCKED%s" "$G" "$X"
}

# Number of concurrent open tunnel connections for $1.
#
# History of wrong approaches here, for the next person who touches this:
#   1. `who`/utmp — Dropbear may not even be built with utmp support, and
#      every connection arrives from 127.0.0.1 (ws.py/HAProxy/SSLH all
#      proxy to it over loopback) so utmp's remote-host field is useless
#      regardless.
#   2. UID-owned process count (`pgrep -u user dropbear`) — wrong too:
#      confirmed on a live server that EVERY Dropbear child stays owned by
#      root, even for authenticated, actively-forwarding sessions. Dropbear
#      only calls setuid() when it execs a shell for the user; our tunnel
#      accounts have shell /bin/false and never exec anything — they're
#      pure port-forwarding, so no shell is ever exec'd and Dropbear has no
#      reason to ever drop privileges. UID-based counting is structurally
#      blind to these sessions.
#
# What actually works: Dropbear's own journal log records the username per
# connection ("Password auth succeeded for 'user'"), tagged with the PID
# that keeps servicing that connection for its entire lifetime (confirmed
# against real log output — same PID from "Child connection" through to
# "Exit (user)"). So: map live Dropbear PIDs -> username via the log, then
# a PID only counts if it's still alive right now.
#
# No caching here: every real caller invokes this via `$(ssh_user_login_count
# ...)` in a per-user loop, and command substitution always forks a fresh
# subshell — a cache variable set inside this function never survives past
# the single call that set it, so memoizing across calls doesn't actually
# work with that call pattern (confirmed: journalctl still ran once per
# call). Re-scanning a --since-bounded window per user is the honest
# trade-off; revisit if this ever becomes a hot path.
_dropbear_pid_user_map() {
  local live
  live="$(pgrep dropbear 2>/dev/null)"
  [[ -z "$live" ]] && return

  # ENVIRON, not awk -v: -v mangles a multi-line value on some awk builds
  # (confirmed on BSD awk; safer to not assume mawk/gawk on the target
  # either). Needs a real `export` — a prefix assignment
  # (`VAR=val cmd1 | cmd2`) only reaches cmd1's environment, not the rest
  # of the pipeline, which awk needs it in (confirmed the hard way: this
  # silently produced empty output with a prefix assignment here before).
  # --since bounds journal-scan cost; widen if long-lived sessions older
  # than this start getting undercounted.
  export DROPBEAR_LIVE_PIDS="$live"
  journalctl -u dropbear --no-pager -o json --since "6 hours ago" 2>/dev/null \
    | jq -r 'select(.MESSAGE | contains("Password auth succeeded for")) | "\(._PID)\t\(.MESSAGE)"' 2>/dev/null \
    | sed -nE "s/^([0-9]+)\t.*succeeded for '([^']+)'.*/\1\t\2/p" \
    | awk -F'\t' '
        BEGIN {
          n = split(ENVIRON["DROPBEAR_LIVE_PIDS"], arr, "\n")
          for (i = 1; i <= n; i++) L[arr[i]] = 1
        }
        ($1 in L) { seen[$1] = $2 }
        END { for (p in seen) print p, seen[p] }
      '
  unset DROPBEAR_LIVE_PIDS
}

# This counts raw connections, not distinct devices — one client app
# commonly opens several parallel sockets, which is exactly why the
# autokill multilogin limit defaults to 2, not 1.
ssh_user_login_count() {
  local user="$1" engine
  engine="$(cat /etc/vpn-script/ssh-engine 2>/dev/null || echo both)"
  if [[ "$engine" == "openssh" ]]; then
    # OpenSSH, unlike Dropbear, setuid()s for every authenticated session
    # regardless of shell vs forwarding-only — UID-based counting is
    # correct here.
    local n
    n="$(pgrep -c -u "$user" sshd 2>/dev/null)"
    echo "${n:-0}"
  else
    _dropbear_pid_user_map | awk -v u="$user" '$2==u' | wc -l | tr -d ' '
  fi
}

# Render the "MEMBER SSH" table (title + rows + account count).
print_ssh_table() {
  local users count=0
  users="$(ssh_user_list)"

  printf '%s\n' "=================================================="
  printf "%20s\n" "MEMBER SSH"
  printf '%s\n' "=================================================="
  echo ""
  printf "%-18s %-16s %s\n" "USERNAME" "EXP DATE" "STATUS"
  echo ""

  if [[ -z "$users" ]]; then
    echo "  (no accounts yet)"
  else
    while read -r u; do
      [[ -z "$u" ]] && continue
      local exp status
      exp="$(ssh_user_expiry "$u")"
      status="$(ssh_user_status "$u" "$exp")"
      printf "%-18s %-16s %b\n" "$u" "$exp" "$status"
      count=$((count + 1))
    done <<< "$users"
  fi

  echo ""
  printf '%s\n' "=================================================="
  echo "Account number: ${count} user"
  printf '%s\n' "=================================================="
}
