# Documenso on `doodlessd`

Self-hosted Documenso behind the nginx-proxy-manager that already fronts this
host, serving `sign.tdpdf.com`. Replaces the Cloudron-hosted instance currently
answering on that hostname.

**Nothing in this directory deploys itself.** The files are copied to the
server by hand and the cutover is a deliberate act with a rollback.

---

## What is pinned, and how it was verified

| Service | Image |
|---|---|
| app | `documenso/documenso:v2.18.0@sha256:126976b9…422650` |
| db | `postgres:17-alpine@sha256:18cfe3ef…be5d73` |

**Documenso 2.x is required.** TDPdf's integration targets the **v2 API**
(`/api/v2`, envelope-based), which did not exist in 1.x. `v2.18.0` is the
newest 2.x release, published 2026-09-09.

Verified against the registry rather than taken from a docs page — a tag that
appears in documentation is not evidence that it is pullable:

```bash
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:documenso/documenso:pull" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  https://registry-1.docker.io/v2/documenso/documenso/manifests/v2.18.0 \
  | grep -i docker-content-digest
# → sha256:126976b9e3be54193e1a3be8d22130af1913aaa894c550b98870a2cc4c422650
```

`HTTP 200` plus a digest, with `linux/amd64` and `linux/arm64` under the index.
Cross-checked against the Docker Hub tag listing (`v2.18.0`, last updated
2026-09-09) and the GitHub release `v2.18.0` of the same date. The digest in
the compose file is the multi-arch index digest; `linux/amd64` beneath it is
`sha256:9e0c3bb164cee0475c56325dd940435055b9cbc75f94cd7af9a4fdbf7e91ec83`.

Both images carry a **tag and a digest**. The tag is for humans; the digest is
what is actually pulled, so an upstream re-tag cannot swap the image underneath
us. Bump both together or neither.

### Auto-update is off, deliberately

The watchtower on this host runs `--label-enable`, i.e. opt-in: it only touches
containers carrying `com.centurylinklabs.watchtower.enable=true`. **Neither
service in `docker-compose.yml` carries that label, and neither should.** This
is a signing service — an unattended bump can migrate the database schema
(Documenso runs Prisma migrations on boot), change the v2 API that TDPdf calls,
or change how documents are signed, and the first symptom would be a failed
signature. Upgrades are a read-the-release-notes, take-a-backup, bump-the-
digest, verify operation.

### Where the environment variables came from

Not guessed. Cross-referenced across three upstream sources, which agree:

- <https://docs.documenso.com/docs/self-hosting/configuration/environment> —
  the full reference, including which are required.
- <https://docs.documenso.com/docs/self-hosting/deployment/docker-compose> —
  the `.env` template.
- <https://github.com/documenso/documenso/blob/main/docker/production/compose.yml>
  — upstream's own production compose, which is where the `:?err` markers show
  exactly which variables the app refuses to start without.

Required: `NEXTAUTH_SECRET`, `NEXT_PRIVATE_ENCRYPTION_KEY`,
`NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY`, `NEXT_PUBLIC_WEBAPP_URL`,
`NEXT_PRIVATE_DATABASE_URL`, `NEXT_PRIVATE_SMTP_TRANSPORT`,
`NEXT_PRIVATE_SMTP_FROM_NAME`, `NEXT_PRIVATE_SMTP_FROM_ADDRESS`. Every one of
them is in `.env.example` with a comment saying what it is and how to generate
it. The signing-certificate variables come from the
[signing certificate](https://docs.documenso.com/docs/self-hosting/configuration/signing-certificate)
pages.

### Signing certificate — read this before believing the Key Vault story

Today this stack uses `NEXT_PRIVATE_SIGNING_TRANSPORT=local`: a `.p12` on disk
at `/home/derek/documenso-stack/secrets/cert.p12`, mounted read-only at
`/opt/documenso/cert.p12`, passphrase from `.env`.

> **TODO (issue #2).** The real SSL.com certificate is to live in **Azure Key
> Vault Premium as a non-exportable RSA-HSM key**. The `local` transport
> **cannot** use it. `local` wants the private key as a file or a base64 blob,
> and the entire point of a non-exportable HSM key is that the private key
> never leaves the vault. Documenso ships three transports — `local`,
> `gcloud-hsm` and `csc` — and none of them speaks Azure Key Vault. Getting
> there needs an `AzureKeyVaultSigner` in our fork and a custom image built
> from it.
>
> **The Key Vault path does not work today and this configuration does not
> pretend otherwise.** Until the signer exists, signing uses a certificate we
> hold on disk. Because it is self-signed, Acrobat shows "signature validity is
> unknown" rather than a green check: the signature still proves the document
> has not been altered since signing, it just is not chained to a root Adobe
> trusts.

The `.p12` **must** have a passphrase. Documenso fails a passwordless one with
`Failed to get private key bags`, which reads like a corrupt file rather than a
missing password. The container runs as uid 1001, so the file needs
`chown 1001` and `chmod 400`. Create it on the host, never inside the container
— a rebuild would lose it and every previously signed document would fail to
verify against its replacement.

### Why it binds to loopback

`127.0.0.1:18100:3000`. nginx-proxy-manager runs in **host network mode** on
this box, so it reaches the app on loopback — the same shape `docs-stack`
(18099) and the relay (18080/18081/19090) already use. Binding `0.0.0.0` would
put an un-TLS'd signing app directly on `199.241.139.240` and on the IPv6
address, in front of Cloudflare rather than behind it. 18100 was chosen because
it is free: something already holds `*:3000` on this host.

Postgres publishes **no** ports at all and is reachable only over the stack's
own compose network.

---

## Before the cutover: does the Cloudron instance hold real signatures?

**Answer this before touching DNS.** `sign.tdpdf.com` currently serves a
Cloudron-hosted Documenso (verified: it answers, redirects to `/signin`, and
`/api/v2/openapi.json` returns 200 — so it is already a 2.x instance).

Documents, their completed signatures and the **audit trail** all live in *that
instance's* database. Repointing DNS does not move them. If anybody has signed
anything real there:

- The new instance starts empty. Signed documents are not merely missing from a
  list — the audit trail that makes a signature defensible is missing too.
- Signing links already issued to counterparties will resolve to the new
  instance and 404.
- A migration is a Postgres dump from the Cloudron instance loaded into the new
  one, and it is only that simple if both are on the same Documenso major
  version *and* the `NEXT_PRIVATE_ENCRYPTION_KEY` moves with it — otherwise
  encrypted columns restore as unreadable ciphertext.

**This runbook does not solve that migration.** It flags it as a gate. Derek
decides: nothing real there → proceed; something real → migration is a separate
piece of work that happens before the cutover, not after.

---

## Deploy

All commands on `doodlessd` unless stated.

### 1. Stage the stack

```bash
mkdir -p /home/derek/documenso-stack/secrets
cd /home/derek/documenso-stack
# copy deploy/docker-compose.yml and deploy/.env.example from this repo
cp .env.example .env && chmod 600 .env
```

### 2. Fill in `.env`

Generate each secret **separately** — never reuse one value for two variables:

```bash
openssl rand -base64 32     # NEXTAUTH_SECRET
openssl rand -base64 32     # NEXT_PRIVATE_ENCRYPTION_KEY
openssl rand -base64 32     # NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY
openssl rand -base64 24 | tr -d '/+=' | cut -c1-32   # POSTGRES_PASSWORD
```

`POSTGRES_PASSWORD` is stripped of `/ + =` because it is also pasted into
`NEXT_PRIVATE_DATABASE_URL`, where those characters need percent-encoding and
will otherwise break the DSN silently.

Put `NEXT_PRIVATE_ENCRYPTION_KEY` in the password manager **now**, before the
stack starts. A restored database without it is unreadable ciphertext.

### 3. Signing certificate

```bash
cd /home/derek/documenso-stack/secrets
openssl genrsa -out private.key 2048
openssl req -new -x509 -key private.key -out certificate.crt -days 365 \
    -subj "/CN=TDPdf Document Signing/O=TDPdf"
openssl pkcs12 -export -out cert.p12 -inkey private.key -in certificate.crt
rm private.key certificate.crt
sudo chown 1001 cert.p12 && sudo chmod 400 cert.p12
```

Record the passphrase in `.env` as `NEXT_PRIVATE_SIGNING_PASSPHRASE` and in the
password manager. Note `-days 365`: put the expiry in the calendar. An expired
signing certificate does not break the app, it breaks *new signatures*.

### 4. Bring it up

```bash
cd /home/derek/documenso-stack
docker compose config -q          # catches a malformed .env before pulling
docker compose up -d
docker compose logs -f documenso  # first boot runs the full Prisma migration set
```

Wait for `documenso-app` to report `healthy` — up to ~3 minutes on first boot.

### 5. Verify over the loopback port, before any DNS change

```bash
curl -sI http://127.0.0.1:18100/            # expect 3xx to /signin
curl -s  http://127.0.0.1:18100/api/v2/openapi.json | head -c 200   # v2 API is live
docker compose ps                            # both healthy
ss -ltn | grep 18100                         # 127.0.0.1 ONLY — never 0.0.0.0
```

That last check is not a formality. If it shows `0.0.0.0:18100`, stop: the app
is on the public internet unprotected.

### 6. Bootstrap the admin account

`NEXT_PUBLIC_DISABLE_SIGNUP=true` in `.env.example` locks the instance down,
which means the **first** account has to be created before that takes effect.
Either:

- temporarily set `NEXT_PUBLIC_DISABLE_SIGNUP=false`, `docker compose up -d`,
  sign up through the loopback port via an SSH tunnel
  (`ssh -L 8100:127.0.0.1:18100 derek@doodlessd`, then
  <http://localhost:8100>), then set it back to `true` and recreate; **or**
- leave signup open only until step 8 and close it immediately after.

The first option never exposes an open signup page on the public hostname. Take
it.

---

## Cutover

### 7. Add the proxy host in nginx-proxy-manager

NPM admin on port 81. Hosts → Proxy Hosts → Add:

| Field | Value |
|---|---|
| Domain Names | `sign.tdpdf.com` |
| Scheme | `http` |
| Forward Hostname / IP | `127.0.0.1` |
| Forward Port | `18100` |
| Cache Assets | off |
| Block Common Exploits | on |
| Websockets Support | **on** |
| SSL | request a new Let's Encrypt certificate, Force SSL on, HTTP/2 on |

Websockets on: Documenso's editor uses them, and the failure without it is a
UI that loads and then silently stops updating — much harder to diagnose than
an outright error.

The Let's Encrypt HTTP-01 challenge needs port 80 to reach *this* host, so the
certificate can only be issued **after** DNS is repointed. Either add the proxy
host without SSL first and request the certificate once DNS has moved, or use a
DNS-01 challenge via the Cloudflare credential if NPM has one configured.

### 8. Repoint DNS

In Cloudflare, `sign.tdpdf.com` currently resolves to Cloudflare edge IPs
(proxied) in front of the Cloudron instance. Change the origin record to:

- `A` → `199.241.139.240`
- `AAAA` → `2602:ff16:4:0:1:20:0:1`
- proxied (orange cloud) stays on — that is the existing posture and Cloudflare
  is what shields the origin IPs.

**Lower the TTL to 60 s at least an hour beforehand.** That hour is what makes
the rollback below fast instead of theoretical.

Do not delete the Cloudron instance. It is the rollback.

### 9. Verify end to end

```bash
dig +short sign.tdpdf.com
curl -sI https://sign.tdpdf.com/            # 3xx to /signin, from OUR origin
curl -s  https://sign.tdpdf.com/api/v2/openapi.json | head -c 200
```

Then in a browser: sign in, upload a PDF, send it to yourself, complete the
signature, download the signed file. **Confirm the email actually arrived** —
SMTP misconfiguration is the single most common way a Documenso instance looks
perfectly healthy and is useless, because every signing request is an email.

Open the signed PDF in Acrobat and confirm the signature panel shows the
expected certificate (validity "unknown" is expected with the self-signed cert
— see the TODO above).

---

## Rollback

The Cloudron instance stays up and untouched throughout. Rollback is a DNS
change, which is why the TTL drop in step 8 matters.

1. Revert the `A`/`AAAA` records to the Cloudron origin. With a 60 s TTL,
   traffic is back within minutes.
2. Leave the new stack running — stopping it destroys the evidence you need to
   work out what went wrong.
3. Disable the NPM proxy host for `sign.tdpdf.com` so the two are not both
   claiming the hostname.

**Anything signed on the new instance between cutover and rollback exists only
in the new instance's database.** Take a dump before trying again:

```bash
docker exec -u postgres documenso-db pg_dumpall --clean --if-exists -U documenso \
  > ~/documenso-rollback-$(date +%F-%H%M).sql
```

Full teardown, only once the decision is final:

```bash
cd /home/derek/documenso-stack && docker compose down    # NOT -v
```

`down`, not `down -v`. The `-v` takes the named volume — and the database —
with it.

---

## Day-two

- **Backups.** `sign.tdpdf.com` holding signed documents with no backup is the
  same mistake in a new place. `PG_CONTAINERS="documenso-db"` in
  `backup.env` is already the default, and `/home/derek/documenso-stack` is
  already in the source list — but verify a snapshot actually contains the dump
  before treating the instance as production. See `../backup/README.md`.
- **Upgrades.** Read the release notes, take a backup, bump **both** the tag
  and the digest in `docker-compose.yml`, `docker compose up -d`, watch the
  migration logs, verify a signature end to end.
- **Certificate expiry.** The self-signed `.p12` above is 365 days. Calendar it.
- **Issue #2** replaces the whole signing block with the Azure Key Vault signer
  and a custom image. Until then, the on-disk `.p12` is the real mechanism, not
  a placeholder for one.
