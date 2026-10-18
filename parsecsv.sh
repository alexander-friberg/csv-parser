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
  samba-tool ou list | grep -qxF "OU=$dept" && return 0
  samba-tool ou create "OU=$dept,$BASE_DN" >/dev/null && log "OK created OU $dept"
}

ensure_group() {
  local dept=$1
  samba-tool group show "$dept" >/dev/null 2>&1 && return 0
  samba-tool group add "$dept" --groupou="OU=$dept" >/dev/null && log "OK created group $dept"
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
  log "OK created user $user ($first $last) in OU=$dept"
}

add_to_group() {
  local user=$1 group=$2
  samba-tool group addmembers "$group" "$user" >/dev/null && log "OK added $user to group $group"
}

create_home() {
  local user=$1
  local dir="$HOME_ROOT/$user"
  mkdir -p "$dir"
  chown "$user" "$dir"
  chmod 700 "$dir"
  setfacl -m "g:domain admins:rwx" -m "d:g:domain admins:rwx" "$dir"
  log "OK created home $dir"
}

process() {
  local user=$1 pass=$2 dept=$3 first=$4 last=$5
  try create_user "$user" "$pass" "$dept" "$first" "$last" &&
  try add_to_group "$user" "$dept" &&
  try create_home "$user"
}

main() {
  local ok=0 failed=0
  while IFS=',' read -r user pass dept first last; do
    is_username "$user" && continue
    if process "$user" "$pass" "$dept" "$first" "$last"; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
  done < "$CSV_FILE" 2>> "$LOG_FILE"
  rm -f "$CSV_FILE"
  log "DONE created=$ok failed/skipped=$failed"
}

main "$@"
