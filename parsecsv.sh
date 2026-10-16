#!/usr/bin/env bash
set -Eeuo pipefail

CSV_FILE="${1:-users.csv}"
LOG_FILE="/srv/admin.log"
BASE_DN="DC=lab,DC=local"
HOME_ROOT="/srv/home"
HOME_UNC="\\\\$(hostname -s)\\home"

log() { printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG_FILE"; }
try() { "$@" || { local rc=$?; log "FAILED step=$1 user=$2 exit=$rc"; return "$rc"; }; }

is_username() { [ "$1" = "username" ]; }

check_user() { 
  if samba-tool user show "$1" >/dev/null 2>&1; then
    log "SKIP $1: username already taken"
    return 1
  fi
}

ensure_ou() {
  samba-tool ou list | grep -qxF "OU=$1" || samba-tool ou create "OU=$1,$BASE_DN"
}

ensure_group() {
  samba-tool group show "$1" >/dev/null 2>&1 || samba-tool group add "$1" --groupou="OU=$1"
}

create_user() {
  check_user "$1" || return 1
  ensure_ou "$4" || return 1
  ensure_group "$4" || return 1
  if ! samba-tool user create "$1" "$5" --given-name="$2" --surname="$3" --userou="OU=$4" \
      --must-change-at-next-login --home-directory="$HOME_UNC\\$1" --home-drive=H:; then
    log "samba-tool user create failed for $1"; return 1
  fi
}

add_to_group() {
  samba-tool group addmembers "$2" "$1"
}

create_home() {
  mkdir -p "$HOME_ROOT/$1"
  chown "$1" "$HOME_ROOT/$1"
  chmod 700 "$HOME_ROOT/$1"
  setfacl -m "g:domain admins:rwx" -m "d:g:domain admins:rwx" "$HOME_ROOT/$1"
}

process() {
  local user=$1 pass=$2 dept=$3 first=$4 last=$5
  is_username "$user" && return 0
  try create_user "$user" "$first" "$last" "$dept" "$pass" &&
  try add_to_group "$user" "$dept" &&
  try create_home "$user"
}

main() {
  while IFS=',' read -r user pass dept first last; do
    process "$user" "$pass" "$dept" "$first" "$last" || continue
  done < "$CSV_FILE" 2>> "$LOG_FILE"
}

main "$@"
