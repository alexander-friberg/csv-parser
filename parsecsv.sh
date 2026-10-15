#!/usr/bin/env bash

CSV_FILE="${1:-users.csv}"

is_header() { [ "$1" = "username" ]; }

create_user() {
  useradd -m -c "$2 $3" -G "$4" "$1"
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
  create_user "$user" "$first" "$last" "$dept"
  set_password "$user" "$pass"
  force_password "$user"
}

main() {
  while IFS=',' read -r user pass dept first last; do
    process_row "$user" "$pass" "$dept" "$first" "$last"
  done < "$CSV_FILE"
}
