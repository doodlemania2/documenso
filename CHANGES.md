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
