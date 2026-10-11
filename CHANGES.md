# Changes to Documenso

This repository builds a modified version of [Documenso](https://github.com/documenso/documenso),
which is licensed under the GNU Affero General Public License v3.0 (`LICENSE`, upstream's,
unmodified). As section 5(a) requires, this file records what we changed and when. The modified
source is upstream at the commit in `fork/pins.env` with the patches in `fork/patches/` applied.

## 2026-10-09 — against v2.18.0 (`389390c884949fe27c240488a3259da3cdba93e0`)

- **Azure Key Vault signing transport** (`fork/patches/0001-signing-azure-key-vault-transport.patch`).
  A new `azure-kv` value for `NEXT_PRIVATE_SIGNING_TRANSPORT` that signs with a non-exportable
  key held in Azure Key Vault, plus tests, documentation and the two Azure SDK dependencies it
  needs. No existing transport's behaviour changes.

## 2026-10-10 — against v2.18.0 (`389390c884949fe27c240488a3259da3cdba93e0`)

- **Seal field values inside the page's visible box** (`fork/patches/0002-seal-respect-visible-box-origin.patch`).
  Fixes an upstream bug: sealing a v2 envelope (and serving a partially signed one) drew field
  values without the page's visible-box origin, mis-scaled them on offset boxes, and ignored an
  inherited `/MediaBox` or `/Rotate`, so on such pages the signed PDF did not match what the signer
  saw. A new `page-overlay-placement.ts` helper computes the placement the way pdf.js displays the
  page; both overlay call sites use it. Adds tests. Ordinary pages are unaffected.
