# Our Documenso build

Upstream Documenso at a pinned release, plus the patches in `patches/`, built
with upstream's own Dockerfile. It exists for one reason today: **signing with
the SSL.com AATL certificate, whose key is a non-exportable RSA-HSM key in
Azure Key Vault** (issue #2). Upstream ships `local`, `gcloud-hsm` and `csc`
signing transports and none of them can use that key.

It is a patch series rather than a full copy of the monorepo on purpose. The
patches are the whole of our change, they stay reviewable, and moving to a new
upstream release is "re-apply and fix what no longer applies" rather than a
merge across thousands of files.

## Licence

Documenso is **AGPL-3.0**, and so is everything here. The root `LICENSE` is
upstream's, unmodified; `CHANGES.md` records what we changed. Serving this
image as `sign.tdpdf.com` obliges us to offer users the corresponding source:
upstream at the commit in `pins.env` plus `patches/` in this repository **is**
that source, so the repository must be reachable by anyone using the instance
once the patched image is live. Keep upstream copyright headers intact.

Nothing here is linked into TDPdf (GPLv3). TDPdf talks to this service over its
HTTP API only.

## Layout

```
fork/
  pins.env        upstream repo, tag, commit; the image tag we produce
  patches/        our changes, as `git apply` patches against that commit
    SHA256SUMS    checked by build.sh before anything is applied
  build.sh        clone, verify, patch, docker build — on the target host
  upstream/       (gitignored) a working clone for editing and testing patches
```

## The patches

### 0001 — Azure Key Vault signing transport (`azure-kv`)

- `packages/signing/transports/azure-key-vault.ts`: a `Signer` for
  `@libpdf/core` that hashes locally and sends only the digest to Key Vault's
  `sign` (`RS256`/`RS384`/`RS512`, i.e. RSASSA-PKCS1-v1_5). Credentials via
  `EnvironmentCredential`. Refuses to start if the certificate's public key is
  not the vault key's public key, and refuses an unversioned key id.
- `packages/signing/index.ts`: registers the `azure-kv` transport.
- `packages/lib/server-only/cert/cert-status.ts`: `/api/certificate-status`
  and `/api/health` understand `azure-kv`. They check the certificate's
  validity period from local configuration only, so health probes never call
  Key Vault.
- `packages/signing/transports/azure-key-vault.test.ts`: 6 tests. The signer
  runs against a stand-in vault that performs Key Vault's exact operation
  (PKCS#1 v1.5 over a precomputed digest); signatures are verified for each
  digest, a key/certificate mismatch is refused, and a real PDF sealed through
  `pdf.sign()` has its CMS verified over the `/ByteRange`. Keys and
  certificates are minted per run — nothing secret is committed. Each check
  was confirmed to fail when the code under it is broken.
- Docs, `.env.example`, `ARCHITECTURE.md`, env typings, and the
  `@azure/identity` / `@azure/keyvault-keys` dependencies (exact versions).

Written to be offered upstream as-is.

**Verified against the real key, 2026-10-10.** The production `AzureKeyVaultSigner`, given the
real chain and the versioned id of `tdpdf-sign/documenso-signing`, passed its own key/certificate
match against the HSM key and sealed a PDF through `pdf.sign()` with the SSL.com TSA. (Only the
credential differed: an Azure CLI token instead of `EnvironmentCredential`, because the signer
service principal did not exist yet.) Poppler `pdfsig`: *Signature is Valid*, signer
`CN=The Doodle Project LLC`, SHA-256, `ETSI.CAdES.detached`. The signature carries an RFC 3161
timestamp, and the document timestamp is SSL.com's (policy `1.3.6.1.4.1.38064.1.3.6.1`), which
`openssl ts -verify` confirms covers the document bytes. Adobe's green check was not yet confirmed.

### 0002 — seal field values inside the page's visible box

Upstream bug, found by TDPdf's integration work. When a v2 envelope is sealed
(`seal-document.handler.ts`, the `internalVersion === 2` branch) — and when a
PENDING envelope is served partially signed (`generate-partial-signed-pdf.ts`,
an identical copy of that code) — the Konva field overlay was sized from
`page.width`/`page.height` and drawn at `(0, 0)` plus a rotation-only
translation. Fields are positioned against what react-pdf (pdf.js) displays,
which is the CropBox clipped to the MediaBox, wherever it sits in user space.
So on any page whose visible box does not start at `(0, 0)` the signer saw the
field in one place and the sealed PDF had it somewhere else:

- the box's lower-left corner was never added, shifting values left/down by it;
- `@libpdf/core` 0.4.2's `getMediaBox()`/`getCropBox()` return the upper-right
  corner as `width`/`height`, so an offset box was also mis-scaled (a CropBox
  `[36 72 576 720]` reads as 576×720 instead of 540×648);
- `/MediaBox` and `/Rotate` inherited from the page tree were ignored (an A4
  page with its MediaBox on `/Pages` sealed as US Letter).

The patch:

- `packages/lib/server-only/pdf/page-overlay-placement.ts` (new):
  `getPageOverlayPlacement` reads the boxes and rotation itself (inherited,
  normalised, CropBox ∩ MediaBox — pdf.js's `Page.view`) and returns the
  overlay's displayed size plus the `drawPage` origin, rotation-aware and
  including the box's own origin. `drawPageOverlay` embeds and draws it.
- Both call sites use it; nothing else changes. On an ordinary page (box at
  the origin, rotation on the page itself) the drawn operators are identical
  to upstream's.
- `page-overlay-placement.test.ts`: 10 tests. Each builds a page (offset
  CropBox at 0/90/180/270/-90, offset MediaBox, CropBox overhanging the
  MediaBox, MediaBox and `/Rotate` inherited), seals an overlay with a field at
  a known percentage, reads the `cm` operators back out of the saved content
  stream, and maps them through a port of pdf.js's `PageViewport`: the overlay
  must cover exactly the displayed page and the field must land at the same
  percentages. Upstream's geometry fails 9 of the 10; dropping only the origin
  fails 8.

Not changed, same class of defect: the v1/legacy pdf-lib inserters
(`insert-field-in-pdf-v1.ts`, `legacy-insert-field-in-pdf.ts`, used only by
`internalVersion === 1` documents, not the v2 envelope API TDPdf uses), the
CSC/TSP stamp overlay (`packages/ee/.../csc/`), and the centred rejection
stamp. Written to be offered upstream as-is.

### 0003 — rebrand to TDPdf Signing

Presentation only; no behaviour changes. One module, `packages/lib/constants/brand.ts`, holds the
name, company, support address and source URL, so a rename is a one-file edit plus
`npm run translate`. The mark is a vector trace of TDPdf's own (`Resources/splash-logo.png`), used
by `BrandingLogo`/`BrandingLogoIcon`; `packages/assets`, `apps/remix/public` and
`packages/email/static` carry the matching PNG/ICO/OG images. The palette moves from lime to TDP
olive (`theme.css`, `tailwind-config`, and the hex mirror `lib/constants/theme.ts`, which must stay
in step). `SiteFooter` (copyright, GitHub, "Based on Documenso (AGPL-3.0)") is on the sign-in pages,
the in-app pages and the mobile menu; the account menu has a "Source code" entry.

Deliberately left alone: `packages/ee`, the admin licence banners (they really are about the
Documenso licence), the Cloud-only upsell cards (never shown self-hosted), webhook/email
`X-Documenso-*` headers, and the `recipient.N@documenso.com` placeholders TDPdf relies on. Other
locales fall back to English for the strings that changed, until they are re-translated.

Not verified in a browser: the app screens (they need Postgres). Typecheck and `lingui extract`
pass, and the email templates were rendered through the preview app.

### 0004 — browser sign-in for TDPdf (`/connect/tdpdf`)

Replaces "create a token in Settings and paste it" for the TDPdf desktop app with the standard
native-app flow (authorization code + PKCE S256, loopback redirect, RFC 8252).

Contract, for the TDPdf client:

1. Generate a random `code_verifier` (43-128 chars of `A-Za-z0-9._~-`), `code_challenge =
   base64url(SHA-256(verifier))`, a random `state`, and listen on `http://127.0.0.1:{port}/cb`.
2. Open `{base}/connect/tdpdf?code_challenge=…&state=…&redirect_uri=http://127.0.0.1:{port}/cb` in the
   browser. The user signs in if needed, picks a team (one they can manage) and clicks Allow.
3. The browser lands on `redirect_uri?code=…&state=…` (or `?error=access_denied&state=…`). Check `state`.
4. `POST {base}/api/connect/token` with JSON `{"code": "…", "code_verifier": "…"}`. Success is
   `200 {"token": "api_…"}`; every failure is `400 {"error": "invalid_grant"}`. The token is an ordinary
   one-year API token named `TDPdf (date)`, listed and revocable under the team's API tokens.

`redirect_uri` must be loopback (`127.0.0.1`, `localhost`, `[::1]`) with an explicit port and no
credentials, otherwise the page says the link is not valid. The code is a signed JWT bound to the
user, team, challenge and redirect; it lives 2 minutes and is single use (tracked in memory, so
sound for one server process). `packages/lib/server-only/connect/tdpdf-connect.test.ts` covers
redirect validation, a wrong or replayed verifier, tampered and foreign-signed codes.

Not done: the token is **not scoped**. Documenso API tokens are all-powerful and scoping means
changing token auth throughout the API, which is a separate and larger patch.

### 0005 — a personal team on first connect

`/connect/tdpdf` used to dead-end with "No team to connect" for a user who could not manage any
team. Signup normally gives every user a "Personal Team" they administer, but creating it is best
effort upstream (`createPersonalOrganisation` logs and swallows a failure), and a user may delete it.
Now clicking Allow runs `ensureConnectableTeam` (`packages/lib/server-only/connect/tdpdf-connect-team.ts`):

- the user has a manageable team: nothing is created;
- they own a personal organisation with no team: the team is added there;
- otherwise: a personal organisation and team are created for them;
- a user in an SSO organisation that forbids personal organisations is left alone and told to ask
  their administrator.

It is deliberately never one shared team for everyone: with open signup, strangers in one team can
see each other's documents. Creation is deduplicated per user within the process (a double click
makes one team); with more than one server process that guard would not hold. The GET of the page
never creates anything.

## Working on the patches

```bash
source ~/.nvm/nvm.sh && nvm use 24          # upstream requires Node >= 24
git clone --depth 1 --branch v2.18.0 https://github.com/documenso/documenso.git fork/upstream
cd fork/upstream
git apply ../patches/*.patch
npm ci
cd packages/signing && npx vitest run && npx tsc --noEmit -p tsconfig.json
cd ../lib && npx vitest run
cd ../.. && npx biome check packages/signing packages/lib/server-only/cert packages/lib/server-only/pdf
```

(`packages/lib` needs `npx prisma generate --schema packages/prisma/schema.prisma`
first, or its type-check drowns in errors from the missing Prisma client.)

After changing code, regenerate the patch you changed — **from its own files
only**, since the working tree carries every patch at once — and the checksums:

```bash
cd fork/upstream && git add -N . && git diff --binary -- <that patch's files> > ../patches/000N-<name>.patch
cd ../patches && shasum -a 256 *.patch > SHA256SUMS
```

Then prove the series still applies in order to a fresh clone of the tag.

and bump the `-tdp.N` suffix of `IMAGE_TAG` in `pins.env`.

## Building

On `doodlessd` (linux/amd64, where the image runs).

**BuildKit is required.** Upstream's Dockerfile creates `WORKDIR /app` after
`USER nodejs`; BuildKit makes that directory owned by `nodejs`, the legacy
builder makes it owned by root, and the runner stage's `npm ci` then fails with
`EACCES` on `/app/node_modules` — after the whole monorepo has built. The host's
Docker 29 had no buildx plugin, so it silently used the legacy builder.
`build.sh` now refuses to start without buildx.

One-time setup on the host, as `derek`, no sudo — buildx v0.37.2 into the
per-user plugin directory, checked against the release's checksums, and a
BuildKit builder container capped at 4 of the 6 cores and 10 GB so the live
stack keeps headroom. Both images are pinned:

```bash
V=v0.37.2
curl -fsSLo /tmp/buildx https://github.com/docker/buildx/releases/download/$V/buildx-$V.linux-amd64
curl -fsSL https://github.com/docker/buildx/releases/download/$V/checksums.txt \
  | grep " \*\?buildx-$V.linux-amd64$" | sed "s/\*//;s#buildx-$V.linux-amd64#/tmp/buildx#" | sha256sum -c -
mkdir -p ~/.docker/cli-plugins && install -m 755 /tmp/buildx ~/.docker/cli-plugins/docker-buildx

docker buildx create --name tdp-capped --driver docker-container \
  --driver-opt image=moby/buildkit:v0.26.2@sha256:de10faf919fc71ba4eb1dd7bd6449566d012b0c9436b1c61bfee21d621b009aa,memory=10g,memory-swap=10g,cpuset-cpus=0-3
```

The host has no git checkout of this repo, so copy the three build inputs over
and build on the capped builder (`--load` puts the result in the host's image
store, where compose can use it):

```bash
ssh derek@doodlessd 'rm -rf ~/documenso-build && mkdir ~/documenso-build'
scp -r fork/build.sh fork/pins.env fork/patches derek@doodlessd:documenso-build/
ssh derek@doodlessd 'cd ~/documenso-build && \
  BUILDKIT_PROGRESS=plain BUILD_EXTRA_ARGS="--builder tdp-capped --load" ./build.sh'
```

`build.sh` refuses to build if the upstream tag no longer resolves to the
pinned commit or a patch does not match `SHA256SUMS`. It prints the image ID;
record it in `deploy/docker-compose.azure-kv.yml`.

## Switching doodlessd to Key Vault signing

All on `doodlessd`, in `/home/derek/documenso-stack` unless noted.

1. **Signer identity** (Paperclip TDP-182): service principal `documenso-signer`
   in tenant `42d6a804-2370-4a3c-95b4-b785a62c6759`, holding **Key Vault Crypto
   User** scoped to the key
   `/subscriptions/96a6c91d-551b-4792-8916-4f9688842b4e/resourceGroups/personal/providers/Microsoft.KeyVault/vaults/tdpdf-sign/keys/documenso-signing`.
2. **Files** in `secrets/`, owned by uid 1001:
   - `signing-chain.pem` — the certificate (`CN=The Doodle Project LLC`,
     SHA-1 `D9E675DF42B0E379ACEBBBA4AF148EF54DF1FCCC`) followed by
     `SSL.com Client Certificate Intermediate CA RSA R2`. Mode 444.
   - `azure-signer.pem` — the service principal's certificate and private key.
     Mode 400.
3. **`.env`**: `AZURE_TENANT_ID` and `AZURE_CLIENT_ID` (see `.env.example`).
4. **Image**: `fork/build.sh`, then check the ID matches the recorded one.
5. **Backup first** (Prisma migrations run at boot; the image is the same
   release, but the rule is the rule): `backup/doodlessd-backup.sh`.
6. **Cut over**:
   `docker compose -f docker-compose.yml -f docker-compose.azure-kv.yml up -d`
7. **Verify**: `/api/certificate-status` reports `isAvailable: true`; sign one
   test document; `pdfsig` (poppler) shows the signature valid, signed by
   `The Doodle Project LLC`, with a timestamp; Adobe Acrobat shows a green
   check.

**Rollback**: `docker compose -f docker-compose.yml up -d` — back to the stock
image and the self-signed `.p12`, which the overlay never removes.

## Upgrading upstream

1. Update `UPSTREAM_TAG` and `UPSTREAM_COMMIT` in `pins.env` (verify the commit
   against the GitHub release, not just the tag), reset `-tdp.N` to `-tdp.1`.
2. Clone the new tag into `fork/upstream/`, `git apply --3way` each patch, fix
   what no longer applies, run the tests above, regenerate the patches and
   `SHA256SUMS`.
3. Read upstream's release notes for schema migrations and v2 API changes
   before building — TDPdf depends on the v2 API.
