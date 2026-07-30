#!/bin/bash
# VPN-Starter-Kit :: core/backup.sh
# Backup / Restore / Autobackup engine, called by both menu/menu-backup.sh
# (interactive bash) and core/admin-panel.py (web panel) -- same
# one-script-many-callers pattern as every other core/*-actions.sh.
#
# Scope: "VPN data only" backups. A backup compiles one manifest.json
# (account lists + settings + toggles) and tars it -- it deliberately
# does NOT include /etc/shadow, WireGuard/OpenVPN private keys, or TLS
# certs. Restoring recreates accounts via the SAME create scripts the
# rest of the app already uses (telegram-ssh/xray/wireguard-actions.sh):
#   - SSH accounts get their ORIGINAL password back (we already keep a
#     plaintext copy in ssh-passwords.json for the "Generate Config"
#     feature, so this is free).
#   - Xray + WireGuard accounts get a FRESH credential/keypair -- there is
#     no "restore this exact UUID/key" path in the create scripts, and
#     inventing one is out of scope for this tier. Affected users need an
#     updated config after a restore; restore's report says so per account.
#
# Google Drive: via rclone, remote must be named exactly "gdrive" (the
# admin configures this once with `rclone config` -- OAuth needs a
# consent step somewhere and there's no way around that from a headless
# script). Restore-by-link uses `rclone backend copyid`, not a plain
# HTTP GET of the share URL -- Google serves an interstitial HTML page
# instead of raw bytes for anonymous downloads of non-tiny files, so a
# plain curl/wget of a drive.google.com link is not reliable here.
#
# Usage:
#   backup.sh create                          (local tar.gz only)
#   backup.sh list-local
#   backup.sh delete-local <filename>
#   backup.sh rclone-status
#   backup.sh upload <filename>                (-> Drive, prints a share link)
#   backup.sh restore <filename>               (from local backups/)
#   backup.sh restore-drive-id <file_id>       (pulled via rclone first)
#   backup.sh autobackup-status
#   backup.sh autobackup-enable <daily|weekly>
#   backup.sh autobackup-disable
#   backup.sh autobackup-run                   (what the cron job calls)
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
CORE_DIR="$INSTALL_DIR/core"
MENU_DIR="$INSTALL_DIR/menu"
BACKUP_DIR="$INSTALL_DIR/backups"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
WG_CLIENTS_JSON="$INSTALL_DIR/wireguard/clients.json"
SSH_LIMITS_JSON="$INSTALL_DIR/ssh-limits.json"
SSH_PASSWORDS_JSON="$INSTALL_DIR/ssh-passwords.json"
BANDWIDTH_HISTORY_JSON="$INSTALL_DIR/bandwidth-history.json"
BACKUP_EMAIL_FILE="$INSTALL_DIR/backup-email-to"
AUTOBACKUP_SCHEDULE_FILE="$INSTALL_DIR/autobackup.schedule"
AUTOBACKUP_CRON="/etc/cron.d/vpn-autobackup"
RCLONE_REMOTE="gdrive"
RCLONE_PATH="vpn-backups"
KEEP_LOCAL_BACKUPS=14

# shellcheck source=menu/lib-ssh-users.sh
[[ -f "$MENU_DIR/lib-ssh-users.sh" ]] && source "$MENU_DIR/lib-ssh-users.sh"

mkdir -p "$BACKUP_DIR"

README_TEXT='This archive is a VPN-Starter-Kit backup (VPN data only -- see
core/backup.sh in the repo for exactly what is and is not included).
It contains one file, manifest.json, meant to be restored with:
  backup.sh restore <this-file>
on a VPN-Starter-Kit VPS. It is not a general system backup.'

# ---- manifest gathering ----

gather_ssh() {
  local users
  users="$(ssh_user_list 2>/dev/null)"
  [[ -z "$users" ]] && { echo "[]"; return; }
  {
    while read -r u; do
      [[ -z "$u" ]] && continue
      local exp pass conn bw
      exp="$(ssh_user_expiry "$u")"
      pass="$(jq -r --arg u "$u" '.[$u] // ""' "$SSH_PASSWORDS_JSON" 2>/dev/null)"
      conn="$(jq -r --arg u "$u" '([.[] | select(.username==$u)][0].conn_limit) // 0' "$SSH_LIMITS_JSON" 2>/dev/null)"
      bw="$(jq -r --arg u "$u" '([.[] | select(.username==$u)][0].bw_limit_mb) // 0' "$SSH_LIMITS_JSON" 2>/dev/null)"
      [[ "$conn" =~ ^[0-9]+$ ]] || conn=0
      [[ "$bw" =~ ^[0-9]+$ ]] || bw=0
      jq -n --arg u "$u" --arg e "$exp" --arg p "$pass" --argjson c "$conn" --argjson b "$bw" \
        '{username:$u, expiry:$e, password:$p, conn_limit:$c, bw_limit_mb:$b}'
    done <<< "$users"
  } | jq -s -c '.'
}

gather_xray_proto() {
  local proto="$1" users=()
  mapfile -t users < <(jq -r --arg p "$proto" '
    [.inbounds[] | select(.protocol==$p) | .settings.clients[].email] | unique[]
  ' "$XRAY_CONFIG" 2>/dev/null)
  {
    for u in "${users[@]}"; do
      [[ -z "$u" ]] && continue
      jq -n --arg u "${u%%_*}" --arg e "${u#*_}" '{username:$u, expiry:$e}'
    done
  } | jq -s -c '.'
}

gather_wireguard() {
  [[ -f "$WG_CLIENTS_JSON" ]] || { echo "[]"; return; }
  jq -c '[.[] | {username, expiry}]' "$WG_CLIENTS_JSON" 2>/dev/null || echo "[]"
}

gather_flags() {
  local keys=("$@")
  {
    for key in "${keys[@]}"; do
      local v=false
      [[ -f "$INSTALL_DIR/${key}.enabled" ]] && v=true
      printf '%s\t%s\n' "$key" "$v"
    done
  } | jq -R -s -c '
    (split("\n") | map(select(length>0))) as $lines |
    ([$lines[] | split("\t") | {(.[0]): (.[1]=="true")}] | add) // {}
  '
}

gather_telegram() {
  local admin_token admin_id admin_enabled user_token user_enabled access
  admin_token="$(cat "$INSTALL_DIR/telegram-bot-token" 2>/dev/null || echo "")"
  admin_id="$(cat "$INSTALL_DIR/telegram-admin-id" 2>/dev/null || echo "")"
  admin_enabled=false; [[ -f "$INSTALL_DIR/telegram-bot.enabled" ]] && admin_enabled=true
  user_token="$(cat "$INSTALL_DIR/telegram-user-bot-token" 2>/dev/null || echo "")"
  user_enabled=false; [[ -f "$INSTALL_DIR/telegram-user-bot.enabled" ]] && user_enabled=true
  access="$(cat "$INSTALL_DIR/telegram-user-bot-access.json" 2>/dev/null || echo '{}')"
  [[ -z "$access" ]] && access='{}'
  jq empty <<< "$access" >/dev/null 2>&1 || access='{}'

  jq -n --arg at "$admin_token" --arg aid "$admin_id" --argjson ae "$admin_enabled" \
        --arg ut "$user_token" --argjson ue "$user_enabled" --argjson acc "$access" \
    '{admin_bot_token:$at, admin_id:$aid, admin_bot_enabled:$ae,
      user_bot_token:$ut, user_bot_enabled:$ue, user_access:$acc}'
}

build_manifest() {
  local ssh_json xray_vmess xray_vless xray_trojan xray_ss wg_json
  local toggles_json security_json telegram_json bw_json
  local domain nsdomain banner engine ar_enabled ar_time

  ssh_json="$(gather_ssh)"
  xray_vmess="$(gather_xray_proto vmess)"
  xray_vless="$(gather_xray_proto vless)"
  xray_trojan="$(gather_xray_proto trojan)"
  xray_ss="$(gather_xray_proto shadowsocks)"
  wg_json="$(gather_wireguard)"
  toggles_json="$(gather_flags haproxy sslh badvpn openvpn proxy stunnel udpcustom)"
  security_json="$(gather_flags fail2ban anti-torrent ddos-protection clean-expired)"
  telegram_json="$(gather_telegram)"
  bw_json="$(cat "$BANDWIDTH_HISTORY_JSON" 2>/dev/null || echo "[]")"
  jq empty <<< "$bw_json" >/dev/null 2>&1 || bw_json="[]"

  domain="$(cat "$INSTALL_DIR/domain" 2>/dev/null || echo "")"
  nsdomain="$(cat "$INSTALL_DIR/ns-domain" 2>/dev/null || echo "")"
  banner="$(cat "$INSTALL_DIR/banner.txt" 2>/dev/null || echo "")"
  engine="$(cat "$INSTALL_DIR/ssh-engine" 2>/dev/null || echo "both")"
  ar_enabled=false; [[ -f "$INSTALL_DIR/autoreboot.enabled" ]] && ar_enabled=true
  ar_time="$(cat "$INSTALL_DIR/autoreboot.time" 2>/dev/null || echo "04:00")"

  jq -n \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg hostname "$(hostname 2>/dev/null || echo unknown)" \
    --arg domain "$domain" --arg nsdomain "$nsdomain" --arg banner "$banner" \
    --arg engine "$engine" --argjson ar_enabled "$ar_enabled" --arg ar_time "$ar_time" \
    --argjson ssh "$ssh_json" \
    --argjson xvmess "$xray_vmess" --argjson xvless "$xray_vless" \
    --argjson xtrojan "$xray_trojan" --argjson xss "$xray_ss" \
    --argjson wg "$wg_json" \
    --argjson toggles "$toggles_json" --argjson security "$security_json" \
    --argjson telegram "$telegram_json" --argjson bw "$bw_json" \
    '{
      backup_version: 1,
      created_at: $created,
      hostname: $hostname,
      settings: {
        domain: $domain, ns_domain: $nsdomain, banner: $banner,
        ssh_engine: $engine, autoreboot_enabled: $ar_enabled, autoreboot_time: $ar_time,
        toggles: $toggles, security: $security
      },
      accounts: {
        ssh: $ssh,
        xray: {vmess: $xvmess, vless: $xvless, trojan: $xtrojan, shadowsocks: $xss},
        wireguard: $wg
      },
      telegram: $telegram,
      bandwidth_history: $bw
    }'
}

# days remaining until an "Mon DD, YYYY" (chage) or ISO expiry date,
# clamped to a minimum of 1 so a just-restored account isn't instantly
# swept by clean-expired; "never" (SSH-only) gets a long runway instead.
days_until() {
  local e="$1" exp_epoch today_epoch days
  if [[ "$e" == "never" || -z "$e" || "$e" == "null" ]]; then
    echo 3650; return
  fi
  exp_epoch="$(date -d "$e" +%s 2>/dev/null || echo 0)"
  today_epoch="$(date +%s)"
  days=$(( (exp_epoch - today_epoch) / 86400 ))
  (( days < 1 )) && days=1
  echo "$days"
}

# ---- restore ----

apply_manifest() {
  local MF="$1" count row u p e c b days bw_gb tmp_out

  echo "===================================================="
  echo " RESTORE REPORT"
  echo "===================================================="
  echo "Backup created: $(jq -r '.created_at // "unknown"' "$MF")"
  echo "From host     : $(jq -r '.hostname // "unknown"' "$MF")"
  echo ""

  echo "--- SSH accounts ---"
  count="$(jq '.accounts.ssh | length' "$MF" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 0 ]]; then
    echo "(none in backup)"
  else
    while read -r row; do
      u="$(jq -r '.username' <<< "$row")"
      p="$(jq -r '.password' <<< "$row")"
      e="$(jq -r '.expiry' <<< "$row")"
      c="$(jq -r '.conn_limit' <<< "$row")"
      b="$(jq -r '.bw_limit_mb' <<< "$row")"
      if id "$u" >/dev/null 2>&1; then
        echo "  SKIP  $u (already exists)"
        continue
      fi
      days="$(days_until "$e")"
      bw_gb=$(( (b + 1023) / 1024 ))
      [[ -z "$p" || "$p" == "null" ]] && p="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 12)"
      tmp_out="$(bash "$CORE_DIR/telegram-ssh-actions.sh" create "$u" "$p" "$days" "$c" "$bw_gb" 2>&1)"
      if [[ $? -eq 0 ]]; then
        echo "  OK    $u (expires in ${days}d, original password restored)"
      else
        echo "  FAIL  $u: $(tail -n1 <<< "$tmp_out")"
      fi
    done < <(jq -c '.accounts.ssh[]' "$MF" 2>/dev/null)
  fi
  echo ""

  local proto
  for proto in vmess vless trojan shadowsocks; do
    echo "--- Xray $proto accounts ---"
    count="$(jq --arg p "$proto" '.accounts.xray[$p] | length' "$MF" 2>/dev/null || echo 0)"
    if [[ "$count" -eq 0 ]]; then
      echo "(none in backup)"
    else
      while read -r row; do
        u="$(jq -r '.username' <<< "$row")"
        e="$(jq -r '.expiry' <<< "$row")"
        days="$(days_until "$e")"
        tmp_out="$(bash "$CORE_DIR/telegram-xray-actions.sh" create "$proto" "$u" "$days" 2>&1)"
        if [[ $? -eq 0 ]]; then
          echo "  OK    $u (expires in ${days}d, NEW credentials issued -- resend config)"
        else
          echo "  FAIL  $u: $(tail -n1 <<< "$tmp_out")"
        fi
      done < <(jq -c --arg p "$proto" '.accounts.xray[$p][]' "$MF" 2>/dev/null)
    fi
    echo ""
  done

  echo "--- WireGuard peers ---"
  count="$(jq '.accounts.wireguard | length' "$MF" 2>/dev/null || echo 0)"
  if [[ "$count" -eq 0 ]]; then
    echo "(none in backup)"
  else
    while read -r row; do
      u="$(jq -r '.username' <<< "$row")"
      e="$(jq -r '.expiry' <<< "$row")"
      if jq -e --arg n "$u" '.[] | select(.username==$n)' "$WG_CLIENTS_JSON" >/dev/null 2>&1; then
        echo "  SKIP  $u (already exists)"
        continue
      fi
      days="$(days_until "$e")"
      tmp_out="$(bash "$CORE_DIR/telegram-wireguard-actions.sh" create "$u" "$days" 2>&1)"
      if [[ $? -eq 0 ]]; then
        echo "  OK    $u (expires in ${days}d, NEW keys issued -- resend config)"
      else
        echo "  FAIL  $u: $(tail -n1 <<< "$tmp_out")"
      fi
    done < <(jq -c '.accounts.wireguard[]' "$MF" 2>/dev/null)
  fi
  echo ""

  echo "--- Settings ---"
  local s_domain s_ns s_banner s_engine v key
  s_domain="$(jq -r '.settings.domain // ""' "$MF")"
  s_ns="$(jq -r '.settings.ns_domain // ""' "$MF")"
  s_banner="$(jq -r '.settings.banner // ""' "$MF")"
  s_engine="$(jq -r '.settings.ssh_engine // ""' "$MF")"
  [[ -n "$s_domain" ]] && { echo "$s_domain" > "$INSTALL_DIR/domain"; echo "  domain -> $s_domain (run Settings -> Save Domain to reissue TLS)"; }
  [[ -n "$s_ns" ]] && { echo "$s_ns" > "$INSTALL_DIR/ns-domain"; echo "  ns-domain -> $s_ns"; }
  [[ -n "$s_banner" ]] && { printf '%s' "$s_banner" > "$INSTALL_DIR/banner.txt"; echo "  banner restored"; }
  [[ -n "$s_engine" ]] && { echo "$s_engine" > "$INSTALL_DIR/ssh-engine"; echo "  ssh-engine -> $s_engine"; }

  for key in haproxy sslh badvpn openvpn proxy stunnel udpcustom fail2ban anti-torrent ddos-protection clean-expired; do
    # has()-based, not //-based: a real `false` value must not be treated
    # the same as "key absent" (jq's // conflates them, which would send
    # the lookup to the wrong object -- toggles vs security -- since //
    # falls through on false too, not just null/missing).
    v="$(jq -r --arg k "$key" '
      if (.settings.toggles | has($k)) then .settings.toggles[$k]
      elif (.settings.security | has($k)) then .settings.security[$k]
      else false end
    ' "$MF")"
    if [[ "$v" == "true" ]]; then touch "$INSTALL_DIR/${key}.enabled"; else rm -f "$INSTALL_DIR/${key}.enabled"; fi
  done
  echo "  service + security toggle flags restored (services not auto-restarted -- use Settings -> Restart All)"
  echo ""
  echo "  Telegram bot tokens are NOT auto-restored (avoids leaving a bot"
  echo "  half-configured) -- reconnect via Bot & Api Setup if this backup had one."
  echo ""

  echo "===================================================="
  echo " RESTORE COMPLETE"
  echo "===================================================="
}

# Accepts a raw Google Drive file ID, or any of the common share-link
# shapes (/file/d/<id>/..., ?id=<id>), and prints just the ID -- lets
# both callers (bash menu, admin-panel.py) pass through whatever the
# user pasted without each having to parse Drive URLs themselves.
extract_drive_id() {
  local input="$1"
  if [[ "$input" =~ /d/([a-zA-Z0-9_-]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$input" =~ [?\&]id=([a-zA-Z0-9_-]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$input" =~ ^[a-zA-Z0-9_-]{10,}$ ]]; then
    echo "$input"
  fi
}

# ---- CLI ----

ACTION="${1:-}"
[[ $# -gt 0 ]] && shift

case "$ACTION" in
  create)
    TS="$(date +%Y%m%d-%H%M%S)"
    FILENAME="vpn-backup-${TS}.tar.gz"
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT
    build_manifest > "$TMPD/manifest.json"
    if ! jq empty "$TMPD/manifest.json" 2>/dev/null; then
      echo "ERROR: failed to build a valid backup manifest."; exit 1
    fi
    printf '%s\n' "$README_TEXT" > "$TMPD/README.txt"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$BACKUP_DIR/$FILENAME" -C "$TMPD" manifest.json README.txt
    chmod 600 "$BACKUP_DIR/$FILENAME"
    SIZE="$(stat -c%s "$BACKUP_DIR/$FILENAME" 2>/dev/null || echo 0)"
    jq -n --arg f "$FILENAME" --arg p "$BACKUP_DIR/$FILENAME" --argjson s "$SIZE" \
          --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{ok:true, filename:$f, path:$p, size_bytes:$s, created_at:$c}'
    ;;

  list-local)
    mkdir -p "$BACKUP_DIR"
    {
      for f in "$BACKUP_DIR"/vpn-backup-*.tar.gz; do
        [[ -e "$f" ]] || continue
        name="$(basename "$f")"
        size="$(stat -c%s "$f" 2>/dev/null || echo 0)"
        mtime="$(stat -c%Y "$f" 2>/dev/null || echo 0)"
        printf '%s\t%s\t%s\n' "$name" "$size" "$mtime"
      done
    } | jq -R -s -c '
      (split("\n") | map(select(length>0))) as $lines |
      {ok:true, backups: ([$lines[] | split("\t") | {filename:.[0], size_bytes:(.[1]|tonumber), mtime:(.[2]|tonumber)}] | sort_by(-.mtime))}
    '
    ;;

  delete-local)
    FN="${1:-}"
    if [[ -z "$FN" || "$FN" == *"/"* ]]; then echo "Invalid filename."; exit 1; fi
    rm -f "${BACKUP_DIR:?}/$FN"
    echo "Deleted $FN."
    ;;

  rclone-status)
    if ! command -v rclone >/dev/null 2>&1; then
      jq -n '{ok:true, installed:false, configured:false}'
      exit 0
    fi
    if rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
      jq -n '{ok:true, installed:true, configured:true}'
    else
      jq -n '{ok:true, installed:true, configured:false}'
    fi
    ;;

  upload)
    FN="${1:-}"
    if [[ -z "$FN" || "$FN" == *"/"* ]]; then echo "Invalid filename."; exit 1; fi
    FILE="$BACKUP_DIR/$FN"
    [[ -f "$FILE" ]] || { echo "Backup file not found: $FN"; exit 1; }
    if ! command -v rclone >/dev/null 2>&1; then
      echo "rclone is not installed. Run: apt install -y rclone"; exit 1
    fi
    if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
      echo "No '${RCLONE_REMOTE}' remote configured. Run: rclone config"
      echo "(name it exactly '${RCLONE_REMOTE}', type: Google Drive)"
      exit 1
    fi
    echo ">>> Uploading $FN to Google Drive (${RCLONE_REMOTE}:${RCLONE_PATH}/)..."
    if ! rclone copy "$FILE" "${RCLONE_REMOTE}:${RCLONE_PATH}/"; then
      echo "ERROR: rclone upload failed."; exit 1
    fi
    LINK="$(rclone link "${RCLONE_REMOTE}:${RCLONE_PATH}/${FN}" 2>/dev/null)"
    if [[ -z "$LINK" ]]; then
      echo "Uploaded, but could not generate a shareable link (check: rclone link ${RCLONE_REMOTE}:${RCLONE_PATH}/${FN})."
      exit 1
    fi
    jq -n --arg l "$LINK" --arg f "$FN" '{ok:true, link:$l, filename:$f}'
    ;;

  restore)
    FN="${1:-}"
    if [[ -z "$FN" || "$FN" == *"/"* ]]; then echo "Invalid filename."; exit 1; fi
    FILE="$BACKUP_DIR/$FN"
    [[ -f "$FILE" ]] || { echo "Backup file not found: $FN"; exit 1; }
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT
    if ! tar -xzf "$FILE" -C "$TMPD" manifest.json 2>/dev/null; then
      echo "ERROR: could not extract manifest.json from $FN (corrupt archive?)."; exit 1
    fi
    if ! jq empty "$TMPD/manifest.json" 2>/dev/null; then
      echo "ERROR: manifest.json in $FN is not valid JSON."; exit 1
    fi
    apply_manifest "$TMPD/manifest.json"
    ;;

  restore-drive-id)
    RAW="${1:-}"
    if [[ -z "$RAW" ]]; then echo "Usage: restore-drive-id <google-drive-link-or-file-id>"; exit 1; fi
    FILE_ID="$(extract_drive_id "$RAW")"
    if [[ -z "$FILE_ID" ]]; then
      echo "ERROR: could not find a Google Drive file ID in that link."; exit 1
    fi
    if ! command -v rclone >/dev/null 2>&1; then
      echo "rclone is not installed. Run: apt install -y rclone"; exit 1
    fi
    if ! rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
      echo "No '${RCLONE_REMOTE}' remote configured. Run: rclone config"
      echo "(name it exactly '${RCLONE_REMOTE}', type: Google Drive)"
      exit 1
    fi
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT
    echo ">>> Fetching file $FILE_ID from Google Drive..."
    if ! rclone backend copyid "${RCLONE_REMOTE}:" "$FILE_ID" "$TMPD/restore-download.tar.gz" 2>&1; then
      echo "ERROR: could not fetch that file from Drive."
      echo "Check the link/ID, and that this VPS's rclone account has access to it."
      exit 1
    fi
    if ! tar -xzf "$TMPD/restore-download.tar.gz" -C "$TMPD" manifest.json 2>/dev/null; then
      echo "ERROR: downloaded file is not a valid backup archive."; exit 1
    fi
    if ! jq empty "$TMPD/manifest.json" 2>/dev/null; then
      echo "ERROR: manifest.json is not valid JSON."; exit 1
    fi
    apply_manifest "$TMPD/manifest.json"
    ;;

  autobackup-status)
    if [[ -f "$AUTOBACKUP_SCHEDULE_FILE" ]]; then
      sched="$(cat "$AUTOBACKUP_SCHEDULE_FILE")"
      jq -n --arg s "$sched" '{ok:true, enabled:true, schedule:$s}'
    else
      jq -n '{ok:true, enabled:false, schedule:null}'
    fi
    ;;

  autobackup-enable)
    SCHED="${1:-daily}"
    case "$SCHED" in
      daily) CRON_EXPR="30 3 * * *" ;;
      weekly) CRON_EXPR="30 3 * * 0" ;;
      *) echo "Schedule must be 'daily' or 'weekly'."; exit 1 ;;
    esac
    echo "$SCHED" > "$AUTOBACKUP_SCHEDULE_FILE"
    mkdir -p /var/log/vpn-script
    echo "$CRON_EXPR root bash $CORE_DIR/backup.sh autobackup-run >> /var/log/vpn-script/autobackup.log 2>&1" > "$AUTOBACKUP_CRON"
    chmod 644 "$AUTOBACKUP_CRON"
    systemctl restart cron >/dev/null 2>&1 || true
    echo "Autobackup ENABLED ($SCHED)."
    ;;

  autobackup-disable)
    rm -f "$AUTOBACKUP_SCHEDULE_FILE" "$AUTOBACKUP_CRON"
    systemctl restart cron >/dev/null 2>&1 || true
    echo "Autobackup DISABLED."
    ;;

  autobackup-run)
    mkdir -p /var/log/vpn-script
    echo "=== Autobackup run: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    RESULT="$("$0" create 2>&1)"
    echo "$RESULT"
    FN="$(jq -r '.filename // empty' <<< "$RESULT" 2>/dev/null)"
    if [[ -z "$FN" ]]; then
      echo "Autobackup: create step failed, aborting."
      exit 1
    fi
    if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:"; then
      "$0" upload "$FN"
    else
      echo "rclone not configured -- backup kept local only."
    fi
    if [[ -f "$BACKUP_EMAIL_FILE" ]]; then
      TO="$(cat "$BACKUP_EMAIL_FILE")"
      if [[ -n "$TO" ]]; then
        python3 "$CORE_DIR/backup-email.py" "$TO" "$BACKUP_DIR/$FN"
      fi
    fi
    ls -1t "$BACKUP_DIR"/vpn-backup-*.tar.gz 2>/dev/null | tail -n "+$((KEEP_LOCAL_BACKUPS + 1))" | xargs -r rm -f
    ;;

  *)
    echo "Usage: backup.sh <create|list-local|delete-local|rclone-status|upload|restore|restore-drive-id|autobackup-status|autobackup-enable|autobackup-disable|autobackup-run> ..."
    exit 1
    ;;
esac
