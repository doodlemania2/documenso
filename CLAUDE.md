# TDPdf signing server (Derek's Documenso fork)

Self-hosted Documenso built from upstream + `fork/patches/`, deployed with `deploy/`, backed up by `backup/`.
Runs on doodlessd. See `README.md`, `fork/README.md`, `deploy/README.md`, `backup/README.md`.

## Alerting
Alerts go to ntfy (https://alert.thedoodleproject.net, topic tdpdf) via SigNoz channel
ntfy-tdpdf. Rules live in scripts/signoz/ and are applied by name; never create rules in the UI.
CI failure notices use the NTFY_URL secret. Tokens are never committed. Mattermost is retired.
Source of truth: K3s docs/current-state.md "alerting moved from Mattermost to ntfy".

Repo specifics:
- The only telemetry this repo produces is the backup job's (service.name `doodlessd-backup`, via
  `backup/lib-otlp.sh` -> oltp-relay -> SigNoz). The Documenso server itself emits none, so there is
  no request-error or availability rule yet; do not add one that queries data that does not exist.
- Rules: `scripts/signoz/alert_rules.py`. Apply: `scripts/signoz/apply_alert_rules.py` (`--check` runs
  every query against real data, `--apply` writes). It defaults to channel `ntfy-tdpdf` and exits
  loudly if that channel is missing. Tests: `python3 -m unittest discover -s tests/signoz -v`.
- CI is in `.github/workflows/`. `ci.yml` runs on every PR and on push to main, on GitHub-hosted
  runners. Five checks are required by branch protection on main: `shellcheck`, `patches`,
  `compose`, `python`, `secrets`. Rename a job only together with the protection rule.
  `image-build.yml` runs `PUSH=0 fork/build.sh` by hand or weekly, on the doodlemanage runner
  (label `doodlemanage-documenso-build`, repo variable `BUILD_RUNNER`, compose file in
  `deploy/doodlemanage/`). Never add a `pull_request` trigger to it: the runner holds the Docker socket.
- Both workflows post failures to ntfy with the `NTFY_URL` secret (plain-text POST with
  Title/Priority/Tags, `|| true`). Any new workflow must do the same.
- Main is protected: a PR is required, the five checks must pass, the branch must be up to date,
  no force push, no deletion. Admin enforcement is OFF so Derek can merge in an emergency.

## Upstream adoption is Derek's call, every time
Never bump `fork/pins.env` to a new upstream release (or deploy one) on your own initiative. When a
new Documenso release exists, tell Derek what changed (release notes, migrations, v2 API changes,
patch conflicts) and wait for a yes. The v2.18.0 -> v2.21.1 sync was done at his request.
