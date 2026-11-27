# Deploying the signing server

Files for running the TDPdf signing server (Documenso plus the patches in `fork/patches/`) with Docker
Compose. The guide for operators is in the Signing section of the TDPdf documentation: *Run the signing server
and upgrade it*. This file is the short version for people working in this repository.

## Files

| File | What it is |
|---|---|
| `docker-compose.yml` | The base stack: the application and a PostgreSQL 17 database. Signs with a certificate file. |
| `docker-compose.azure-kv.yml` | Overlay that signs with a key held in Azure Key Vault. See `fork/README.md`. |
| `docker-compose.image.yml` | Pins the application image by tag and digest. **Written by the deploy workflow. Do not edit it by hand.** |
| `doodlessd/deploy.sh` | Rolls the stack to the pinned image. Used by the deploy workflow. |
| `doodlemanage/` | Compose file for the image build runner. |

Run them together, in this order: `docker-compose.yml`, `docker-compose.azure-kv.yml` (if you use Key
Vault), `docker-compose.image.yml`.

## Rules the stack follows

- **Automatic updates stay off.** Neither service carries an update label. An unattended update can migrate
  the database, change the API that TDPdf calls, or change how documents are signed.
- **Pin by tag and digest.** The tag is for people; the digest is what is pulled. Change both together.
- **The database has no published ports.** The application binds to loopback only; put an HTTPS proxy with
  WebSocket support in front of it.
- **Documents live in the database** (`NEXT_PUBLIC_UPLOAD_TRANSPORT=database`), so one `pg_dumpall` covers
  documents, signatures and the audit trail. See `backup/README.md` before changing this.
- **Documenso 2.x is required.** TDPdf uses the v2 API.

## First start

1. Create a stack folder and copy the compose files into it.
2. Copy `.env.example` to `.env`, set mode 600, and fill it in. Generate each secret separately with
   `openssl rand -base64 32`. Save `NEXT_PRIVATE_ENCRYPTION_KEY` in your password manager **before** you start:
   a database restored without it is unreadable.
3. Provide a signing certificate: a `.p12` with a passphrase, readable by user 1001, mounted read-only. Replacing
   it needs `docker compose up -d --force-recreate documenso`.
4. `docker compose config -q`, then `docker compose up -d`. The first start runs the migrations and can take up
   to three minutes. Wait for `healthy`.
5. Check the application answers on its loopback port and is **not** bound to `0.0.0.0`.
6. Send yourself a document, sign it and confirm the email arrives. A server with broken mail looks healthy and
   does nothing.

If you close sign-up (`NEXT_PUBLIC_DISABLE_SIGNUP=true`), create the first account before you do.

## Upgrading

Adopting a new upstream release is a decision for the maintainer, not a routine bump. The steps:

1. Read the release notes: migrations, v2 API changes, patch conflicts.
2. Take a backup and check it.
3. Update `fork/pins.env`. The workflow builds the image, opens a pull request that pins its digest, and deploys
   after the checks pass.
4. Send and sign a test document.

`deploy.sh` refuses to install an older version over a newer one, saves a database dump to `predeploy/`, pulls by
digest, waits for the container to be healthy, and restores the old files if it is not. A rollback does not undo
migrations; restore the dump first if the schema changed.

Use `docker compose down`, never `down -v`: the `-v` option deletes the database volume.

## How a deploy reaches the server

The deploy job in `.github/workflows/deploy.yml` runs on a runner that has no Docker access to the server. It
copies the compose files and `deploy.sh` over a restricted SSH command and runs the script there. It runs only on
a push to `main` or by hand, never on a pull request, because its key can change the server.

## Signing certificate

A self-signed certificate works, but Acrobat reports the signature's validity as unknown. The signature still
proves the document has not changed. To sign with a publicly trusted certificate whose private key never leaves a
hardware module, use the Key Vault overlay. Put the certificate's expiry in a calendar: an expired certificate
does not stop the app, it stops new signatures.
