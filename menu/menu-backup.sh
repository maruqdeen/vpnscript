#!/bin/bash
# VPN-Starter-Kit :: menu/menu-backup.sh
# Backup submenu. Thin interactive wrapper around core/backup.sh, same
# one-script-many-callers pattern as menu-security.sh / core/security.sh.
set -uo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi

INSTALL_DIR="/etc/vpn-script"
CORE_DIR="$INSTALL_DIR/core"
BACKUP_SH="$CORE_DIR/backup.sh"
BACKUP_EMAIL_FILE="$INSTALL_DIR/backup-email-to"

BL=$'\e[38;5;111m'; Y=$'\e[33m'; G=$'\e[32m'; R=$'\e[31m'; X=$'\e[0m'

pause() { read -rp $'\nPress Enter to continue...' _; }

center() {
  local text="$1" width=52 pad
  pad=$(( (width - ${#text}) / 2 ))
  (( pad < 0 )) && pad=0
  printf "%${pad}s%s\n" "" "$text"
}

# ---- [1] Backup Now ----
backup_now() {
  echo ">>> Compiling backup..."
  RESULT="$(bash "$BACKUP_SH" create)"
  echo "$RESULT"
  FN="$(jq -r '.filename // empty' <<< "$RESULT" 2>/dev/null)"
  if [[ -z "$FN" ]]; then
    echo "Backup failed -- see the error above."
    return
  fi
  SIZE_KB=$(( $(jq -r '.size_bytes // 0' <<< "$RESULT") / 1024 ))
  echo ""
  echo "Backup saved: $FN (${SIZE_KB} KB)"

  RCSTATUS="$(bash "$BACKUP_SH" rclone-status)"
  if [[ "$(jq -r '.configured' <<< "$RCSTATUS")" == "true" ]]; then
    echo ""
    read -rp "Upload to Google Drive now? [y/N]: " up
    if [[ "$up" =~ ^[Yy]$ ]]; then
      UPRESULT="$(bash "$BACKUP_SH" upload "$FN")"
      LINK="$(jq -r '.link // empty' <<< "$UPRESULT" 2>/dev/null)"
      if [[ -n "$LINK" ]]; then
        echo ""
        echo "Google Drive link (copy this):"
        echo "  $LINK"
      else
        echo "$UPRESULT"
      fi
    fi
  else
    echo ""
    echo "(Google Drive not connected -- run 'rclone config' to set up a"
    echo " remote named exactly 'gdrive' if you want cloud uploads.)"
  fi

  echo ""
  read -rp "Email this backup to an address now? [y/N]: " em
  if [[ "$em" =~ ^[Yy]$ ]]; then
    read -rp "Send to: " TO
    if [[ -n "$TO" ]]; then
      python3 "$CORE_DIR/backup-email.py" "$TO" "$INSTALL_DIR/backups/$FN"
    fi
  fi
}

# ---- [2] Restore ----
restore_menu() {
  echo ""
  echo "  [1] Restore from a local backup"
  echo "  [2] Restore from a Google Drive link"
  echo "  [0] Back"
  read -rp "Choose: " opt
  case "$opt" in
    1) restore_local ;;
    2) restore_drive ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

restore_local() {
  LIST="$(bash "$BACKUP_SH" list-local)"
  COUNT="$(jq '.backups | length' <<< "$LIST" 2>/dev/null || echo 0)"
  if [[ "$COUNT" -eq 0 ]]; then
    echo "No local backups yet -- run Backup Now first."
    return
  fi
  echo ""
  echo "Local backups:"
  jq -r '.backups | to_entries[] | "  [\(.key+1)] \(.value.filename)  (\(.value.size_bytes/1024|floor) KB)"' <<< "$LIST"
  echo ""
  read -rp "Restore which number? (0 to cancel): " n
  [[ "$n" == "0" || -z "$n" ]] && return
  FN="$(jq -r --argjson i "$((n-1))" '.backups[$i].filename // empty' <<< "$LIST" 2>/dev/null)"
  if [[ -z "$FN" ]]; then echo "Invalid selection."; return; fi
  echo ""
  echo "This will recreate accounts/settings from '$FN' on THIS server."
  echo "Existing accounts with the same username are skipped, not overwritten."
  read -rp "Continue? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }
  bash "$BACKUP_SH" restore "$FN"
}

restore_drive() {
  echo ""
  read -rp "Paste the Google Drive link (or file ID) of your backup: " LINK
  [[ -z "$LINK" ]] && { echo "Cancelled."; return; }
  echo ""
  echo "This will recreate accounts/settings from that file on THIS server."
  echo "Existing accounts with the same username are skipped, not overwritten."
  read -rp "Continue? [y/N]: " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; return; }
  bash "$BACKUP_SH" restore-drive-id "$LINK"
}

# ---- [3] Set Autobackup ----
set_autobackup() {
  STATUS="$(bash "$BACKUP_SH" autobackup-status)"
  if [[ "$(jq -r '.enabled' <<< "$STATUS")" == "true" ]]; then
    echo "Autobackup: ${G}ENABLED${X} ($(jq -r '.schedule' <<< "$STATUS"))"
  else
    echo "Autobackup: ${R}DISABLED${X}"
  fi
  NOTIFY="$(cat "$BACKUP_EMAIL_FILE" 2>/dev/null || echo "(none)")"
  echo "Notification email: $NOTIFY"
  echo ""
  echo "  [1] Enable -- Daily (03:30)"
  echo "  [2] Enable -- Weekly (Sun 03:30)"
  echo "  [3] Disable"
  echo "  [4] Set/clear notification email"
  echo "  [0] Back"
  read -rp "Choose: " opt
  case "$opt" in
    1) bash "$BACKUP_SH" autobackup-enable daily ;;
    2) bash "$BACKUP_SH" autobackup-enable weekly ;;
    3) bash "$BACKUP_SH" autobackup-disable ;;
    4)
      read -rp "Notification email (blank to clear): " TO
      if [[ -z "$TO" ]]; then
        rm -f "$BACKUP_EMAIL_FILE"
        echo "Notification email cleared."
      else
        echo "$TO" > "$BACKUP_EMAIL_FILE"
        echo "Notification email set to $TO."
        echo "(Make sure SMTP is configured in Settings first, or sends will fail silently.)"
      fi
      ;;
    0) return ;;
    *) echo "Invalid option." ;;
  esac
}

while true; do
  clear
  echo ""
  printf '%s\n' "===================================================="
  center "BACKUP MANAGER"
  printf '%s\n' "===================================================="
  echo ""
  printf "  ${BL}[1]${X} Backup\n"
  printf "  ${BL}[2]${X} Restore\n"
  printf "  ${BL}[3]${X} Set Autobackup\n"
  echo ""
  printf "  ${Y}[0]${X} Main Menu\n"
  echo ""
  read -rp " Select menu : " opt

  case "$opt" in
    1) backup_now ; pause ;;
    2) restore_menu ; pause ;;
    3) set_autobackup ; pause ;;
    0) exit 0 ;;
    *) echo "Invalid option."; sleep 1 ;;
  esac
done
