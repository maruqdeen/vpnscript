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

# Number of DISTINCT devices currently logged in as $1 (Dropbear writes utmp
# entries, so `who` sees tunnel sessions). Counts unique remote IPs rather
# than raw session lines, since one device commonly opens several parallel
# WS sockets — that must not look like multilogin. Falls back to raw line
# count if no remote-host info is present in utmp.
ssh_user_login_count() {
  local user="$1" rows ips
  rows="$(who 2>/dev/null | awk -v u="$user" '$1==u')"
  [[ -z "$rows" ]] && { echo 0; return; }
  ips="$(grep -oE '\([^)]+\)' <<< "$rows" | sort -u | wc -l | tr -d ' ')"
  if [[ "$ips" -gt 0 ]]; then
    echo "$ips"
  else
    wc -l <<< "$rows" | tr -d ' '
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
