# documenso

Two things live in this repo:

1. **`deploy/`** — the self-hosted [Documenso](https://github.com/documenso/documenso)
   stack that runs on the server `doodlessd` and serves `sign.tdpdf.com`.
2. **`backup/`** — whole-host backups for `doodlessd`. Not Documenso-only:
   before this work the server had **no backups of any kind**, so the backup
   set covers every stack on the box.

It is also where **our fork of Documenso** will live when we need one. Issue #2
(the `AzureKeyVaultSigner`) is the first thing that will require it — Documenso
upstream has no signing transport that can use a non-exportable RSA-HSM key in
Azure Key Vault, so that has to be our code in our image.

## Licensing — read this before pushing a fork here

Documenso is **AGPL-3.0**. That is not the MIT-shaped obligation most of our
dependencies carry, and the difference matters specifically because we run it
as a network service:

- **Network use is distribution.** AGPL §13: if you modify the program and let
  users interact with it *over a network*, you must offer those users the
  Corresponding Source of **your modified version**. Standing up
  `sign.tdpdf.com` on a patched build triggers this. Nobody has to ask first.
- **The offer has to be real and prominent.** In practice: keep the "Source"
  link Documenso ships in its own UI working and pointed at our fork, or add
  one. A private repo is fine *until* we serve a modified build publicly; at
  that point the modified source must be obtainable by the people using it.
- **Attribution stays intact.** Do not strip Documenso copyright headers,
  `LICENSE`, or upstream branding from source files. Rebranding the *product
  surface* is a separate question from erasing *authorship*, and only the
  former is ours to do.
- **Our modifications inherit AGPL-3.0.** Anything we add to the fork —
  `AzureKeyVaultSigner` included — ships under AGPL-3.0, not under whatever
  licence TDPdf uses. Keep TDPdf (GPLv3) and this fork as separate codebases
  talking over the HTTP API; do not link our signer into TDPdf's process.

If the fork is added, put upstream's `LICENSE` at the repo root unmodified and
record our changes in a `NOTICE`-style changelog so the source offer is easy to
satisfy.

## Layout

```
deploy/                 the runnable stack + the cutover runbook
  docker-compose.yml    documenso + postgres, pinned, loopback-bound
  .env.example          every variable, placeholders only
  README.md             deployment, cutover, rollback
backup/                 whole-host backups for doodlessd
  README.md             design, retention, and the restore rehearsal
  install-restic.sh     pinned restic install (not the stale apt package)
  doodlessd-backup.sh   the backup job
  doodlessd-prune.sh    retention + integrity check
  restore-rehearsal.sh  proves the backup restores, on a throwaway copy
  backup.env.example    destination + credentials, placeholders only
  systemd/              units and timers
```

## Ground rules for this repo

- **No secrets, ever.** `.env`, `backup.env`, `*.p12` are gitignored. The
  committed `.example` files carry placeholders and a note on how to generate
  the real value.
- **Everything pinned.** Images carry both a tag and a digest; `latest` is
  never used. Auto-update is deliberately off — see the watchtower note in
  `deploy/docker-compose.yml`.
- **Nothing here deploys itself.** These files are copied to the server by
  hand, on purpose. The cutover is a human decision with a rollback.
