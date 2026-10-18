# csv-parser

Bulk-creates Samba Active Directory users from a CSV file. Each user is placed in an OU for their department, added to a matching department group, and given a personal home directory with the right permissions. The script can be run directly on the domain controller or deployed with Ansible.

## Requirements

On the domain controller:

- Samba running as an AD DC (`samba-tool` available)
- `winbind` enabled for `passwd` and `group` in `/etc/nsswitch.conf`, so domain users and groups resolve on the server
- The `acl` package (`setfacl`)
- `/srv/home` shared as `[home]` in `smb.conf`
- Root privileges

To deploy with Ansible:

- Ansible on your machine
- SSH key access to the domain controller, with a user that can use `sudo`

## CSV format

```csv
username,password,department,firstname,lastname
anna.svensson,Welcome2026!a,Sales,Anna,Svensson
```

- The header row is skipped.
- Use Unix line endings (LF) and end the file with a newline.
- Fields can't contain commas.
- Passwords must meet the domain's password complexity rules.
- The CSV holds plaintext passwords. It is deleted after each run and ignored by git (`*.csv` in `.gitignore`).

## Usage

### On the domain controller

```sh
sudo bash parsecsv.sh users.csv
```

If no file is given, the script reads `users.csv` from the current directory.

### With Ansible

Set the domain controller's address and SSH user in `inventory.ini`:

```ini
[dc]
dc1 ansible_host=192.168.122.10 ansible_user=alex
```

Put `users.csv` next to the playbook and run:

```sh
ansible-playbook -i inventory.ini deploy.yml --ask-become-pass
```

The playbook copies the script to `/usr/local/sbin/parsecsv.sh` (mode `0755`), copies the CSV to `/root/users.csv` (mode `0600`), and runs the script.

## What it does

For each row in the CSV:

1. Skips the user if the username already exists.
2. Creates the OU `OU=<department>` if it doesn't exist.
3. Creates a group named after the department in that OU if it doesn't exist.
4. Creates the user in the department OU with first and last name. The user must change their password at next login, and `H:` is mapped to `\\<server>\home\<username>`.
5. Adds the user to the department group.
6. Creates `/srv/home/<username>`, owned by the user, mode `700`, with an ACL that gives `Domain Admins` full access.

## Logging

Everything is logged to `/srv/admin.log`:

```
2026-10-18T13:10:02+02:00 OK created OU Marketing
2026-10-18T13:10:02+02:00 OK created group Marketing
2026-10-18T13:10:03+02:00 OK created user ida.petersson (Ida Petersson) in OU=Marketing
2026-10-18T13:10:03+02:00 OK added ida.petersson to group Marketing
2026-10-18T13:10:03+02:00 OK created home /srv/home/ida.petersson
2026-10-18T13:10:04+02:00 SKIP anna.svensson: username already taken
2026-10-18T13:10:12+02:00 DONE created=12 failed/skipped=8
```

- `OK`: a step succeeded
- `SKIP`: the user already exists
- `FAILED`: a step failed, with the step name, the user and the exit code
- `DONE`: summary at the end of the run

A failure for one user doesn't stop the rest of the run.

## Re-running

Add new rows to the CSV and run again. Existing users are skipped and only new ones are created. Changing or removing a row doesn't update or delete an existing user.

## Configuration

These variables at the top of `parsecsv.sh` can be changed:

| Variable | Default | Purpose |
|---|---|---|
| `LOG_FILE` | `/srv/admin.log` | Log file |
| `BASE_DN` | `DC=lab,DC=local` | Domain base DN that department OUs are created under |
| `HOME_ROOT` | `/srv/home` | Where home directories are created |
| `HOME_UNC` | `\\<hostname>\home` | Share path used for the user's `H:` drive |
