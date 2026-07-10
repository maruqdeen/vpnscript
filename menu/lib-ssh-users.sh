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
# NOT `who`/utmp: Dropbear may not be built with utmp support at all (this
# was the bug — it silently always read 0), and even when it is, every
# connection into Dropbear arrives from 127.0.0.1 (ws.py, or now
# HAProxy/SSLH all proxy to it over loopback), so utmp's "remote host"
# field is useless for telling devices apart here regardless.
#
# Instead: count live Dropbear/OpenSSH processes owned by that user's UID.
# Whichever daemon authenticates a connection drops privileges to the
# authenticated user for the life of the session — an OS-level fact, not
# an optional logging feature — and this is true no matter which of the
# entry paths (ws.py, HAProxy, SSLH) the connection came in through.
#
# This counts raw connections, not distinct devices — one client app
# commonly opens several parallel sockets, which is exactly why the
# autokill multilogin limit defaults to 2, not 1.
ssh_user_login_count() {
  local user="$1" engine proc n
  engine="$(cat /etc/vpn-script/ssh-engine 2>/dev/null || echo both)"
  [[ "$engine" == "openssh" ]] && proc="sshd" || proc="dropbear"
  n="$(pgrep -c -u "$user" "$proc" 2>/dev/null)"
  echo "${n:-0}"
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
