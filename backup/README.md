# doodlessd backups

Before this, **`doodlessd` had no backups of any kind.** Verified on the host:
no `restic`, `borg`, `duplicity` or `rclone` installed; no backup entry in
cron; no backup systemd timer. The only artefact resembling one was a manual
`npm-backup-2.11.3-20260907.tar.gz` sitting in `/home/derek` — on the same disk
as the thing it backs up.

That is why this directory is not Documenso-specific. The server fronts every
hostname we serve through nginx-proxy-manager, and the blast radius of losing
it is not one app.

---

## The one decision that is not made here

**`RESTIC_REPOSITORY` is deliberately left as a placeholder.** Derek picks the
destination; nothing in this repo invents a provider or a credential.

> **A backup stored on the machine it protects is not a backup.**
> If `doodlessd` loses its disk, gets ransomwared, or is deleted by the
> hosting provider, a restic repository on `/var/backups` dies in the same
> instant as the data. It would have looked perfectly healthy every day until
> then — which is worse than nothing, because it buys false confidence.

`backup.env` is the single variable. restic speaks all of these behind one
interface, so the choice changes one line and nothing else:

| Backend | `RESTIC_REPOSITORY` | Needs |
|---|---|---|
| SFTP | `sftp:backup@host:/srv/restic/doodlessd` | an SSH key for `root@doodlessd`, ideally an append-only restricted account |
| S3 / compatible | `s3:s3.amazonaws.com/bucket/doodlessd` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`; enable object lock |
| Backblaze B2 | `b2:bucket:doodlessd` | `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` |
| rclone | `rclone:remote:path` | an existing rclone remote (OneDrive, Azure Blob, …) |

`doodlessd-backup.sh` refuses to run if `RESTIC_REPOSITORY` is unset, still the
placeholder, or a local filesystem path. That refusal is a feature: a green
timer pointing at local disk is the exact failure this is guarding against.

**Whatever is chosen, prefer append-only.** The host holds the credential, so
anything that can compromise the host can delete the backups unless the remote
end forbids it — restic's REST server `--append-only`, an S3 bucket with object
lock, or a B2 key without `deleteFiles`. The weekly prune then has to run from
somewhere else, or with a second, privileged credential kept off this host.

---

## Why restic

- **Encrypted client-side, always** — not a flag. That is what makes it
  acceptable to send `/etc/oltp-relay`, the stacks' `.env` files and a full
  Documenso dump to somebody else's bucket.
- **Real deduplication** (content-defined chunking). A daily `pg_dumpall` of a
  slowly-changing database costs almost nothing after the first.
- **One static binary, no daemon, no client-side database.** Nothing that can
  itself be "down".
- **Many backends behind one interface**, so the destination stays a decision
  rather than an architecture.
- **File-granular restores and `restic mount`**, which is what makes the
  monthly rehearsal cheap enough that it actually happens.

`borg` was the other serious candidate. It loses on one point that matters
here: remote repositories need `borg` installed on the *remote* end, which
constrains the destination before the destination has been chosen.

The Ubuntu package is **not** used — noble ships 0.16.4, and repository format
v2 (native compression) plus several prune correctness fixes landed after that.
`install-restic.sh` fetches the upstream binary and verifies its SHA-256.

---

## What is backed up, and why each thing is in the list

| Source | Why |
|---|---|
| `pg_dumpall` of `documenso-db` (staged) | the Documenso database — **and its documents**, see below |
| hot copy of NPM's `database.sqlite` (staged) | every proxy host, redirect and access list on this box |
| `/data/compose/27/data` | NPM's `keys.json` (its column-encryption key), generated nginx vhosts |
| `/data/compose/27/letsencrypt` | account keys, live certs, renewal config |
| `/home/derek/*-stack` | every stack's compose file and `.env` |
| `/home/derek/docker-compose.yml` | the host-level stack |
| `/opt/oltp-relay/deploy`, `/opt/oltp-relay/collector` | the relay stack and the collector config |
| `/etc/oltp-relay` | the relay's API keys — root-only, outside the stack dir |
| `/etc/doodlessd-backup` | this system's own config; a restore that cannot restore the restorer is a nasty surprise |
| `docker ps/volumes/images`, `dpkg -l`, enabled units (staged) | the inventory that turns a file restore into a rebuild instead of archaeology |

**Excluded:** `${NPM_DATA}/logs` (155 MB of access logs, rewritten constantly,
worth nothing at restore time and would dominate the change rate),
`*.bak-*`, `*.tar.gz`, and anything marked with a `CACHEDIR.TAG`.

**Also excluded, on purpose:** the `deploy_queue` docker volume. It is the otel
collector's outbound spool — in-flight telemetry with a retention measured in
minutes. Restoring a week-old spool would replay stale metrics into SigNoz.

### Documenso's documents

`NEXT_PUBLIC_UPLOAD_TRANSPORT=database`, so uploaded PDFs, the completed signed
documents and the audit trail are all **rows in Postgres**. One `pg_dumpall`
captures them together, consistently, with nothing to keep in step.

If that is ever switched to `s3`, this backup silently stops covering documents
— the dump would still succeed, still be a valid dump, and simply no longer
contain the files. Switching the transport means adding an object-store leg
here and a matching check in `restore-rehearsal.sh`.

### Why Postgres is dumped and not file-copied

A file-level copy of a running Postgres data directory **is not a backup**.

The postmaster writes 8 KB pages while the copy walks the tree, so some files
are captured before a write and some after: torn pages, an index pointing at a
row version absent from the heap you copied, a control file naming a WAL
position whose segment you missed. The copy *looks* fine — right size, restic
reports success, the volume mounts. It fails at restore time, under pressure,
when Postgres either refuses to start or, worse, starts and serves subtly wrong
data.

A physical backup *can* be made consistent, but only with `pg_basebackup` or
`pg_backup_start()`/`pg_backup_stop()` plus every WAL segment generated in
between — a whole extra mechanism with its own failure modes. At this data
volume a logical dump is consistent by construction: `pg_dumpall` runs inside
one snapshot-isolation transaction, so it is a point-in-time view regardless of
what the application does during it.

`pg_dumpall`, not `pg_dump`: it also captures **roles and grants**. A restore
that recreates the tables but not the role that owns them fails on the first
`GRANT`, and you get to debug permissions during an outage.

The dump runs **inside the container**. The host's `pg_dump` is 16.15, the
container runs Postgres 17, and `pg_dump` refuses to dump a server newer than
itself. Using the container's own binaries makes that skew impossible now and
after any future major-version bump.

The same tearing argument applies in miniature to NPM's SQLite file, which is
why it gets a hot copy through `sqlite3`'s online backup API (via `python3` —
the `sqlite3` CLI is not installed on this host and is not in the NPM image)
rather than a plain `cp`.

---

## Schedule and retention

| Unit | When | Does |
|---|---|---|
| `doodlessd-backup.timer` | daily 03:17 UTC ±15 m | dump, stage, `restic backup` |
| `doodlessd-prune.timer` | Sun 05:40 UTC ±30 m | `restic forget --prune`, `restic check --read-data-subset=5%` |

Retention: **14 daily, 8 weekly, 12 monthly, 3 yearly.** The dailies cover "I
deleted it last week and only just noticed"; the weeklies and monthlies cover a
slow-burning corruption nobody spotted at the time.

Both timers are `Persistent=true`, so a run missed because the host was down
happens at next boot instead of being silently skipped. Prune is a separate
timer so a slow prune can never delay or fail a backup — a backup that did not
happen is a real loss, a prune that did not happen is a slightly larger bill.

`restic check` alone only verifies *metadata*: that the index is internally
consistent. It will call a repository healthy while the pack files underneath
have rotted or been truncated by a flaky upload. `--read-data-subset=5%`
actually downloads and re-hashes a rotating slice, so the whole repository gets
verified over about five months without ever downloading it all at once.

---

## How a failed backup is noticed

Wired into what the host already runs: `relay-gate` on `127.0.0.1:18080` in
front of an OpenTelemetry collector that ships to SigNoz. No new notification
channel.

Three layers, because they catch different failures:

1. **In-script `ERR` trap** → OTLP log record, `severityText=ERROR`, naming the
   step that broke (`postgres dumps`, `restic backup`, …). Most actionable, but
   only fires if bash is still alive.
2. **`OnFailure=doodlessd-backup-failed@%n.service`** → OTLP log record with
   the unit result and the last 25 journal lines. Catches what the trap cannot:
   OOM kill, `SIGKILL`, `TimeoutStartSec`, or a failure before the config was
   even loaded.
3. **A success heartbeat gauge**, `backup.last_success.timestamp`, carrying a
   unix timestamp.

Layer 3 is the one that matters most and is the easiest to leave out. An
`OnFailure` hook **cannot fire for a unit that never ran** — masked, disabled
"just for a minute" during maintenance, or on a host that was down. The alert
is therefore about *absence*, and it is defined as code in `scripts/signoz/alert_rules.py`
(rule "TDPdf Backup - No successful backup in 36 hours", plus a second rule for any ERROR log).
Apply with `scripts/signoz/apply_alert_rules.py`; both page ntfy topic `tdpdf` through SigNoz
channel `ntfy-tdpdf`. Never create them in the UI. The condition is:

```
now() - backup.last_success.timestamp > 36h   → alert
```

36 h, not 25 h: one skipped day on a daily schedule is a blip, two is a
pattern, and a threshold that pages on every transient network wobble gets
muted within a fortnight.

A further alert on `backup.snapshot.count` going *down* outside a prune window (the
signature of retention eating more than it should) is deliberately not written yet: the gauge has
never arrived, so there is no real series to set a threshold against. Add it once weeks of data exist.

**`OTLP_API_KEY` is empty in the template.** Issue one with
`relayctl issue --tenant doodlessd-backup` on the relay host; it is printed
exactly once. Until it is set, backups still run and still succeed — silently.
Treat an empty value as a to-do, not a setting.

---

## Install

Nothing here deploys itself. From a checkout on the server:

```bash
sudo ./backup/install-restic.sh
```

Installs restic 0.19.1 (SHA-256 verified), the scripts, the units, and
`/etc/doodlessd-backup/backup.env` from the template. **It does not enable the
timers.** Then, in order:

```bash
# 1. Fill in the destination, the repo password and the OTLP key.
sudoedit /etc/doodlessd-backup/backup.env

# 2. Store RESTIC_PASSWORD in the password manager BEFORE this line.
#    There is no recovery, no escrow and no support line without it.
set -a; . /etc/doodlessd-backup/backup.env; set +a
restic init

# 3. One run by hand, watched.
sudo systemctl start doodlessd-backup.service
journalctl -u doodlessd-backup.service -f

# 4. Rehearse a restore BEFORE trusting any of it.
sudo /usr/local/sbin/doodlessd-restore-rehearsal.sh

# 5. Only then.
sudo systemctl enable --now doodlessd-backup.timer doodlessd-prune.timer
sudo systemctl list-timers 'doodlessd-*'
```

Keep a second copy of `RESTIC_PASSWORD` somewhere that does not depend on
`doodlessd` *or* on the password manager being reachable. The two ways to lose
everything are losing the password and never testing the restore, and this
document exists to prevent both.

---

## Restore runbook

### The rehearsal — run it monthly

```bash
sudo /usr/local/sbin/doodlessd-restore-rehearsal.sh
```

Non-destructive. It restores the newest snapshot to `/var/tmp`, loads the
Postgres dump into a **throwaway** container (`restore-rehearsal-pg`, no
published ports, no bind mounts), queries real rows out of it, runs
`PRAGMA integrity_check` on the restored NPM database, confirms the
certificates and stack configs are present, then removes everything.

It fails loudly if any of that does not hold. **A non-zero exit is an
outage-in-waiting, not a flaky test.** Record each successful run below.

| Date | Result | By |
|---|---|---|
| _(not yet run — the first rehearsal is part of standing this up)_ | | |

Re-run it, not just on the schedule, but after **any** change to the
destination, the retention policy, or the Postgres major version.

### Real restore — one file

```bash
set -a; . /etc/doodlessd-backup/backup.env; set +a
restic snapshots --tag doodlessd
restic restore <snapshot-id> --target /var/tmp/r \
  --include /home/derek/documenso-stack/docker-compose.yml
```

Or browse first — usually faster than guessing at paths:

```bash
mkdir -p /mnt/restic && restic mount /mnt/restic    # Ctrl-C to unmount
```

### Real restore — the Documenso database

Destructive to the live database. Take a fresh dump first if the container is
still running at all.

```bash
cd /home/derek/documenso-stack
docker compose stop documenso            # stop the app, NOT the database

restic restore latest --tag doodlessd --target /var/tmp/r \
  --include /var/backups/doodlessd/pg_dumpall_documenso-db.sql

# ON_ERROR_STOP=1 matters. Without it psql skips failing statements and
# reports success, leaving a half-restored database that looks fine.
docker compose exec -T -u postgres database \
  psql -v ON_ERROR_STOP=1 -U postgres -d postgres \
  < /var/tmp/r/var/backups/doodlessd/pg_dumpall_documenso-db.sql

docker compose up -d documenso
docker compose logs -f documenso
```

The dump is `--clean --if-exists`, so it drops and recreates as it goes and is
safe to replay onto a cluster that already has objects.

> **The encryption keys are not in the dump.** A restored database without the
> matching `NEXT_PRIVATE_ENCRYPTION_KEY` has ciphertext nobody can read — API
> tokens and 2FA secrets are gone even though every row is present. Restore
> `.env` from the same snapshot, or from the password manager, **before**
> starting the app.

### Real restore — nginx-proxy-manager

This is the one that takes every hostname on the box down while it is broken,
so read the whole thing before starting.

```bash
restic restore latest --tag doodlessd --target /var/tmp/r \
  --include /var/backups/doodlessd/npm-database.sqlite \
  --include /data/compose/27

cd /home/derek/npm-stack && docker compose down

cp -a /data/compose/27/data /data/compose/27/data.broken.$(date +%F)   # keep the evidence
cp /var/tmp/r/var/backups/doodlessd/npm-database.sqlite /data/compose/27/data/database.sqlite
cp /var/tmp/r/data/compose/27/data/keys.json             /data/compose/27/data/keys.json
cp -a /var/tmp/r/data/compose/27/letsencrypt/.           /data/compose/27/letsencrypt/

docker compose up -d
curl -sI http://127.0.0.1:81 | head -1     # NPM admin should answer
```

Use the **hot-copied** `npm-database.sqlite`, not the `database.sqlite` from
the file tree — the staged copy is the consistent one; the file-tree copy was
taken from a live writer.

`keys.json` is not optional. NPM encrypts columns with it; the SQLite file
without it is not a usable restore.

### Full host rebuild

1. Fresh Ubuntu 24.04, install docker + compose plugin.
2. `install-restic.sh`, then restore `/etc/doodlessd-backup/backup.env` — or
   rebuild it from the password manager, since you need `RESTIC_PASSWORD`
   before you can restore anything at all. **This is the chicken-and-egg step,
   and it is why the password lives outside this host.**
3. `restic restore latest --tag doodlessd --target /` — review
   `docker-ps.txt`, `docker-images.txt` and `docker-volumes.txt` from the
   snapshot first; they name every container and the exact image digest each
   one ran.
4. Restore NPM (above) and bring it up before anything else, so hostnames
   resolve to something while the rest comes back.
5. Bring up each stack from its restored compose file.
6. Restore the Documenso database, then start Documenso.
7. Re-run the rehearsal against the new host.
