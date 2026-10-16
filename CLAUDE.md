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
- There are no GitHub workflows here. If one is added, notify failures with the `NTFY_URL` secret
  (plain-text POST with Title/Priority/Tags, `|| true` so a failed notice never fails the job).
