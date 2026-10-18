# csv-parser

Bulk-creates Samba Active Directory users from a CSV file. Each user is placed in an OU for their department, added to a matching department group, and given a personal home directory with the right permissions. The script can run on the domain controller itself or on a separate file server that manages the domain controller over the network, and it can be deployed with Ansible.

## Requirements

On the domain controller:

- Samba running as an AD DC (`samba-tool` available)
- `winbind` enabled for `passwd` and `group` in `/etc/nsswitch.conf`, so domain users and groups resolve on the server
- The `acl` package (`setfacl`)
- `/srv/home` shared as `[home]` in `smb.conf`
- Root privileges

To deploy with Ansible:

- Ansible on your machine
- SSH key access to the server that runs the script, with a user that can use `sudo`

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
[useradmin]
dc1 ansible_host=192.168.122.10 ansible_user=alex
```

Put `users.csv` next to the playbook and run:

```sh
ansible-playbook -i inventory.ini deploy.yml --ask-become-pass
```

The playbook copies the script to `/usr/local/sbin/parsecsv.sh` (mode `0755`), copies the CSV to `/root/users.csv` (mode `0600`), and runs the script.

## Separate file server

By default the script runs on the domain controller and calls `samba-tool` locally. If home directories live on a separate file server, run the script there instead and set `DC_URL` to the domain controller's address. Every `samba-tool` call then goes to the domain controller over LDAP, authenticated with Kerberos (`-H "$DC_URL" --use-kerberos=required`), and home directories are created on the file server's local disk. `HOME_UNC` follows the file server's hostname, so users get `\\<fileserver>\home\<username>` as `H:`.

### Requirements on the file server

- Joined to the domain, with `winbind` enabled for `passwd` and `group` in `/etc/nsswitch.conf`
- `samba-tool` (`samba-common-bin` on Debian) and `acl` installed
- `/srv/home` shared as `[home]` in `smb.conf`
- A Kerberos ticket for an account allowed to create users and groups

### Running it by hand

```sh
kinit administrator
sudo -E DC_URL=ldap://dc1.lab.local bash parsecsv.sh users.csv
```

`-E` keeps your environment so root can use your Kerberos ticket.

### Running it with Ansible

The playbook gets a ticket from a keytab, so it needs no password at run time.

1. On the domain controller, create a service account and export its keytab:

   ```sh
   sudo samba-tool user create svc-useradmin --random-password
   sudo samba-tool group addmembers "Domain Admins" svc-useradmin
   sudo samba-tool domain exportkeytab /root/parsecsv.keytab --principal=svc-useradmin
   ```

2. Fetch the keytab to `files/parsecsv.keytab`, encrypt it with Ansible Vault, and remove the copy on the domain controller:

   ```sh
   mkdir -p files
   ansible -i inventory.ini useradmin -b -K -m fetch \
     -a "src=/root/parsecsv.keytab dest=files/parsecsv.keytab flat=yes"
   ansible-vault encrypt files/parsecsv.keytab
   ssh alex@192.168.122.10 'sudo rm /root/parsecsv.keytab'
   ```

   Run the fetch while the domain controller is still the host in `[useradmin]`, before switching the inventory in the next step.

3. Point `[useradmin]` at the file server and set `dc_url`:

   ```ini
   [useradmin]
   fs1 ansible_host=192.168.122.11 ansible_user=alex dc_url=ldap://dc1.lab.local
   ```

4. Run the playbook with the vault password:

   ```sh
   ansible-playbook -i inventory.ini deploy.yml --ask-become-pass --ask-vault-pass
   ```

When `dc_url` is set, the playbook copies the keytab to `/etc/parsecsv.keytab` (mode `0600`), runs `kinit` as `svc-useradmin`, runs the script with `DC_URL`, and removes the ticket with `kdestroy`. When `dc_url` isn't set, those steps are skipped and the script runs locally, so the same playbook works for both setups.

Never commit the vault password. In production, give the service account rights only to create users and groups in the department OUs instead of making it a member of `Domain Admins`.

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
- `INTERRUPTED`: the run was stopped with Ctrl+C (exit code 130)
- `TERMINATED`: the run was stopped with `kill` (SIGTERM, exit code 143)
- `ABORTED`: the script stopped early, with its exit code. Logged after `INTERRUPTED` and `TERMINATED`, and when the script crashes, for example on an unbound variable

A failure for one user doesn't stop the rest of the run. A run that stops early has no `DONE` line and ends with `ABORTED`:

```
2026-10-18T14:02:11+02:00 INTERRUPTED
2026-10-18T14:02:11+02:00 ABORTED exit=130
```

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
| `DC_URL` | empty | Domain controller to manage over the network, e.g. `ldap://dc1.lab.local`. Read from the environment; empty means run `samba-tool` locally |
