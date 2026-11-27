# Backups

Scripts and units that back up the signing server's host. The guide for operators is in the Signing section of
the TDPdf documentation: *Back up and restore the signing server*. This file explains what is here and why.

## The destination is your decision

`RESTIC_REPOSITORY` in `backup.env.example` is a placeholder, on purpose. **A backup stored on the machine it
protects is not a backup:** a lost disk or a compromised host destroys both. The script refuses to run if the
repository is unset, still the placeholder, or a local path.

| Backend | `RESTIC_REPOSITORY` | Needs |
|---|---|---|
| SFTP | `sftp:user@host:/path` | an SSH key, ideally for an append-only account |
| S3 or compatible | `s3:endpoint/bucket/path` | access keys; turn on object lock |
| Backblaze B2 | `b2:bucket:path` | account id and key |
| rclone | `rclone:remote:path` | an existing rclone remote |

Prefer a destination the host cannot delete from, so that a compromised host cannot erase its own backups.
Prune from somewhere else, or with a second credential kept off the host.

## Why restic

It always encrypts on the client, deduplicates, ships as one static binary with no daemon, supports many
backends behind one interface, and can mount a snapshot to browse it. `install-restic.sh` downloads a pinned
version and checks its SHA-256.

## What is backed up

| Source | Why |
|---|---|
| `pg_dumpall` of the database container (staged) | The documents, signed PDFs, audit trail and accounts. |
| The stack folders, with their `.env` files | The secrets and compose files. |
| The reverse proxy's database, keys and certificates | Needed to bring the sites back. |
| This system's own configuration | A restore that cannot restore the restorer is a surprise. |
| An inventory of containers, volumes, images and packages | Turns a file restore into a rebuild. |

Excluded: access logs, `*.bak-*`, `*.tar.gz`, cache folders and the telemetry spool volume.

**Documents are in the database** while `NEXT_PUBLIC_UPLOAD_TRANSPORT=database`. If that is changed to an object
store, the dump still succeeds but no longer contains the files. Add a leg for the store and a matching check in
`restore-rehearsal.sh` first.

**Dump, never copy.** A file copy of a running PostgreSQL data folder can look fine and fail to start on restore.
`pg_dumpall` is consistent by construction and also saves roles and grants. It runs inside the container, so its
version always matches the server.

## Schedule

| Unit | When | Does |
|---|---|---|
| `doodlessd-backup.timer` | daily, early morning UTC | dump, stage, `restic backup` |
| `doodlessd-prune.timer` | weekly | `restic forget --prune`, then `restic check --read-data-subset=5%` |

Retention is 14 daily, 8 weekly, 12 monthly and 3 yearly snapshots. Both timers are persistent, so a run missed
while the host was down happens at the next start. Prune is a separate unit so a slow prune never delays a backup.

## Noticing a failure

1. An `ERR` trap sends a log record naming the step that failed.
2. An `OnFailure` unit sends a record with the unit result and the last journal lines, which catches kills and
   timeouts the trap cannot.
3. A success heartbeat, `backup.last_success.timestamp`. The alert rule fires when no success has been seen for
   36 hours, which also covers a unit that never ran. Rules live in `scripts/signoz/alert_rules.py`; do not create
   them in a UI.

`OTLP_API_KEY` is empty in the template. Until you set it, backups run and succeed silently.

## Install

```sh
sudo ./backup/install-restic.sh        # installs restic, scripts, units and a backup.env template
sudoedit /etc/doodlessd-backup/backup.env   # destination, repository password, OTLP key
set -a; . /etc/doodlessd-backup/backup.env; set +a
restic init                            # store RESTIC_PASSWORD in your password manager first
sudo systemctl start doodlessd-backup.service
sudo /usr/local/sbin/doodlessd-restore-rehearsal.sh
sudo systemctl enable --now doodlessd-backup.timer doodlessd-prune.timer
```

The installer does not enable the timers. Keep a second copy of `RESTIC_PASSWORD` somewhere that depends on
neither the server nor the password manager.

## Restore

**Rehearsal, monthly.** `doodlessd-restore-rehearsal.sh` restores the newest snapshot, loads the dump into a
throwaway container with no published ports, queries real rows, checks the proxy database and removes everything.
A non-zero exit is an outage waiting to happen. Re-run it after any change to the destination, the retention or
the PostgreSQL major version.

**One file.** `restic snapshots`, then `restic restore <id> --target /var/tmp/r --include <path>`. Use
`restic mount` to browse first.

**The database.** Take a fresh dump first if the container still runs. Stop the application but not the database,
restore the dump file, then load it:

```sh
docker compose exec -T -u postgres database psql -v ON_ERROR_STOP=1 -U postgres -d postgres < dump.sql
```

`ON_ERROR_STOP=1` matters: without it psql skips failing statements and reports success. The dump uses
`--clean --if-exists`, so it is safe to replay. The encryption keys are not in the dump: restore the `.env` from
the same snapshot before you start the application, or API tokens and two-factor secrets are lost.

**The reverse proxy.** Stop it, keep the broken data folder aside, restore the staged hot copy of its database
(not the live file), its keys file and its certificates, then start it and check the admin page answers.
