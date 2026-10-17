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
  local user=$1
  if samba-tool user show "$user" >/dev/null 2>&1; then
    log "SKIP $user: username already taken"
    return 1
  fi
}

ensure_ou() {
  local dept=$1
  samba-tool ou list | grep -qxF "OU=$dept" || samba-tool ou create "OU=$dept,$BASE_DN"
}

ensure_group() {
  local dept=$1
  samba-tool group show "$dept" >/dev/null 2>&1 || samba-tool group add "$dept" --groupou="OU=$dept"
}

create_user() {
  local user=$1 pass=$2 dept=$3 first=$4 last=$5
  check_user "$user" || return 1
  ensure_ou "$dept" || return 1
  ensure_group "$dept" || return 1
  if ! samba-tool user create "$user" "$pass" --given-name="$first" --surname="$last" --userou="OU=$dept" \
      --must-change-at-next-login --home-directory="$HOME_UNC\\$user" --home-drive=H:; then
    log "samba-tool user create failed for $user"; return 1
  fi
}

add_to_group() {
  local user=$1 group=$2
  samba-tool group addmembers "$group" "$user"
}

create_home() {
  local user=$1
  local dir="$HOME_ROOT/$user"
  mkdir -p "$dir"
  chown "$user" "$dir"
  chmod 700 "$dir"
  setfacl -m "g:domain admins:rwx" -m "d:g:domain admins:rwx" "$dir"
}

process() {
  local user=$1 pass=$2 dept=$3 first=$4 last=$5
  is_username "$user" && return 0
  try create_user "$user" "$pass" "$dept" "$first" "$last" &&
  try add_to_group "$user" "$dept" &&
  try create_home "$user"
}

main() {
  while IFS=',' read -r user pass dept first last; do
    process "$user" "$pass" "$dept" "$first" "$last" || continue
  done < "$CSV_FILE" 2>> "$LOG_FILE"
  rm -f "$CSV_FILE"
}

main "$@"
