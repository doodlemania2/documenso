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

## 2026-10-16 — against v2.18.0 (`389390c884949fe27c240488a3259da3cdba93e0`)

- **Rebrand to TDPdf Signing** (`fork/patches/0003-rebrand-tdpdf-signing.patch`). The product name,
  logo, favicons, social images, web manifest and colour palette are now TDPdf's; user-facing text
  and the emails say "TDPdf Signing"; the support page points at our contact address instead of
  Documenso Inc.'s channels; the Documenso-Cloud promotional links ("View plans", "Check out
  Documenso") are gone. A footer shows our copyright, a GitHub link and "Based on Documenso
  (AGPL-3.0)" so the source offer required by section 13 is visible to every user. Nothing under
  `packages/ee` is touched (it is under Documenso's commercial licence), and identifiers other
  software depends on are unchanged: webhook and email `X-Documenso-*` headers and the
  `recipient.N@documenso.com` stand-in addresses.

- **Browser sign-in for the TDPdf desktop app** (`fork/patches/0004-tdpdf-browser-sign-in.patch`).
  A new `/connect/tdpdf` page and `POST /api/connect/token` endpoint implement the OAuth
  authorization-code flow with PKCE (S256) and a loopback redirect, so TDPdf can obtain an API token
  without the user pasting one. Adds tests. No existing behaviour changes.

## 2026-10-16 — against v2.18.0 (`389390c884949fe27c240488a3259da3cdba93e0`)

- **A personal team on first connect** (`fork/patches/0005-tdpdf-connect-personal-team.patch`).
  Connecting TDPdf needs a team the user can manage. A user who has none (signup creates the
  personal team best effort; upstream swallows a failure there, and a user can delete it) is now
  given a personal organisation and team of their own when they click Allow on `/connect/tdpdf`,
  instead of being shown "No team to connect". Never a shared team: with open signup, strangers in
  one team would see each other's documents. Adds tests.


## 2026-10-23 — rebased onto v2.21.1 (`8707e33c124e4b1a68dde92d5e05178c9aabd0be`)

- All five patches re-applied to v2.21.1 (from v2.18.0). `0003` (rebrand) needed hand resolution in
  the two layouts, four email templates and `send-reset-password.ts`, where upstream moved to
  `getEmailAssetUrl` and added legal links and a subject line; the "View plans" button upstream
  re-added to the self-signed email stays removed. `package-lock.json` was regenerated for the two
  Azure SDK dependencies. No behaviour of ours changed.

## 2026-10-26 — against v2.21.1

- **Zoho SalesIQ chat widget on every page** (`fork/patches/0006-tdpdf-zoho-salesiq-widget.patch`).
  The widget snippet is added to the `<head>` in `apps/remix/app/root.tsx`, nonced for the CSP.
