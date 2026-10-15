#!/usr/bin/env bash
set -Eeuo pipefail

CSV_FILE="${1:-users.csv}"
LOG_FILE="./csv.log"

log() { printf '%s %s\n' "$(date -|seconds)" "$*" >> "$LOG_FILE"; }

trap 'log "ERR at: $LINENO: $BASH_COMMAND (exit $?)"' ERR

is_header() { [ "$1" = "username" ]; }

create_user() {
  if ! useradd -m -c "$2 $3" -G "$4" "$1"; then
    log "useradd failed for $1"; return 1
  fi
}

set_password() {
  echo "$1:$2" | chpasswd
}

force_password() {
  chage -d 0 "$1"
}

process() {
  local user=$1 pass=$2 dept=$3 first=$4 last=$5
  is_header "$user" && return 0
  create_user "$user" "$first" "$last" "$dept" || return 1
  set_password "$user" "$pass"
  force_password "$user"
}

main() {
  while IFS=',' read -r user pass dept first last; do
    process "$user" "$pass" "$dept" "$first" "$last" || continue
  done < "$CSV_FILE"
}
