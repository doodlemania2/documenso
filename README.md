# TDPdf Signing — self-hosted Documenso

This repository runs **[sign.tdpdf.com](https://sign.tdpdf.com)**, the document-signing service
behind [TDPdf](https://github.com/doodlemania2/TDPdf). It is a self-hosted
[Documenso](https://github.com/documenso/documenso) instance with one addition: it can seal
documents with a **publicly trusted signing certificate whose private key never leaves a hardware
security module** in Azure Key Vault. Signed PDFs validate in Adobe Acrobat and every other
standards-compliant reader, and carry RFC 3161 timestamps so they keep validating after the
certificate expires.

Everything needed to reproduce it is here: the patch we add to Documenso, the script that builds
the image, the Docker Compose stack, and the backups. You are welcome to read it, reuse it, or run
your own copy.

## What's in here

| Path | What it is |
|---|---|
| [`fork/`](fork/) | Our Documenso build: upstream at a pinned release, plus a small patch series, built with upstream's own Dockerfile. Start with [`fork/README.md`](fork/README.md). |
| [`fork/patches/`](fork/patches/) | The changes we make to Documenso: an **Azure Key Vault signing transport** (`azure-kv`), and a fix so sealed field values land where the signer saw them on pages whose visible box is offset. |
| [`deploy/`](deploy/) | The Docker Compose stack (Documenso + Postgres), with a [deployment runbook](deploy/README.md). `docker-compose.azure-kv.yml` is the overlay that switches signing to Key Vault. |
| [`backup/`](backup/) | Whole-host backups with restic, including a restore rehearsal that proves the backups actually restore. See [`backup/README.md`](backup/README.md). |
| [`LICENSE`](LICENSE), [`CHANGES.md`](CHANGES.md) | Documenso's AGPL-3.0 licence, unmodified, and the record of what we changed. |

## Signing with Azure Key Vault

Documenso ships signing transports for a local `.p12` file, Google Cloud HSM, and CSC providers.
None of them can use a key held in Azure Key Vault — and a publicly trusted document-signing
certificate (for example one in Adobe's AATL) is only issued for a key generated and kept in an
HSM, so the `.p12` route is closed for exactly the certificates people want.

The `azure-kv` transport fills that gap. Documenso hashes the document locally and sends only the
digest to Key Vault's `sign` operation; the key itself never leaves the vault. It checks at startup
that the configured certificate really belongs to the vault key, and it requires a versioned key
id so a certificate renewal can never silently change the signing key. Configuration and setup are
documented in the patch itself (`apps/docs/.../signing-certificate/azure-key-vault.mdx`) and
summarised in [`fork/README.md`](fork/README.md).

The patch is written so it could be offered to Documenso upstream as-is. If you run Documenso and
want Key Vault signing, you can apply it to v2.18.0 directly:

```bash
git clone --depth 1 --branch v2.18.0 https://github.com/documenso/documenso.git
cd documenso && git apply /path/to/fork/patches/0001-signing-azure-key-vault-transport.patch
```

## Source code offer (AGPL-3.0)

Documenso is licensed under the GNU Affero General Public License v3.0, and so is our modified
version. If you use sign.tdpdf.com, the complete corresponding source for the version it runs is:

- Documenso at the upstream commit pinned in [`fork/pins.env`](fork/pins.env), plus
- the patches in [`fork/patches/`](fork/patches/), applied in order.

[`fork/build.sh`](fork/build.sh) turns those into the exact image we run. Documenso's copyright
notices and licence are kept intact; [`CHANGES.md`](CHANGES.md) lists our modifications.

TDPdf itself (GPLv3) talks to this service only over Documenso's HTTP API; no Documenso code is
linked into it.

## How we run it

A few principles shape everything here, in case you adapt it for your own deployment:

- **No secrets in the repository.** Real `.env` files, certificates and keys are gitignored. Every
  committed `.example` file uses placeholders and explains how to produce the real value.
- **Everything is pinned.** Images are referenced by tag *and* digest (or, for the image we build
  ourselves, by recorded image ID); the upstream source is pinned to a commit and every patch to a
  checksum. Automatic updates are deliberately off for a signing service.
- **Changes are deliberate and reversible.** Nothing deploys itself. The switch to Key Vault
  signing is an overlay file, so moving to it — and rolling back — is one command each.

## Contributing

Issues and pull requests are welcome, especially around the Key Vault transport. For anything
about Documenso itself, the [upstream project](https://github.com/documenso/documenso) is the right
place.
