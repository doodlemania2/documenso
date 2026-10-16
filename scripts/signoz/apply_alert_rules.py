#!/usr/bin/env python3
"""Apply the TDPdf server's SigNoz alert rules (channel ntfy-tdpdf, ntfy topic tdpdf). Report-only by default.

    SIGNOZ_API_KEY=<key> python3 scripts/signoz/apply_alert_rules.py
    SIGNOZ_API_KEY=<key> python3 scripts/signoz/apply_alert_rules.py --check
    SIGNOZ_API_KEY=<key> python3 scripts/signoz/apply_alert_rules.py --apply

Rules are matched by their ``alert`` name, so a re-run UPDATES rather than duplicates,
and the script never touches a rule it does not define. Definitions live in
``alert_rules.py``. Standard library only — there is nothing to install.

``--check`` runs every query through the query API first. A rule whose SQL is wrong is
accepted by SigNoz and then fails silently forever, logging ``query result is nil``
while looking perfectly healthy in the UI, so check before you apply. A query that
returns zero rows is fine and expected before the host has reported anything; a query
that returns an ERROR is the thing to catch.

Getting the key (the public otlp. host is ingest-only and 401s every query — the
query and rules APIs are cluster-only, over LAN or Tailscale):

    export KUBECONFIG=/Volumes/Data/repos/K3s/kubeconfig-tailscale.yaml
    SIGNOZ_API_KEY=$(kubectl --request-timeout=20s -n signoz \\
      get secret signoz-query-api-key -o jsonpath='{.data.key}' | base64 -d)

Every rule needs a notification channel and SigNoz refuses one that names none.
Creating a channel needs a SigNoz ADMIN — the read/write service-account key returns
403 — so the channel is made once by an admin (webhook type, ntfy URL with ?template=alertmanager)
and this script attaches to it BY NAME. Rules are never created in the UI.
"""
import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from alert_rules import RULES  # noqa: E402

BASE = os.environ.get("SIGNOZ_URL", "https://signoz.cluster.thedoodleproject.net")
CHANNEL = os.environ.get("SIGNOZ_CHANNEL", "ntfy-tdpdf")
SOURCE = "tdpdf-server"
MANAGED_BY = "scripts/signoz/apply_alert_rules.py"

# The cluster serves its own certificate over Tailscale.
_TLS = ssl.create_default_context()
_TLS.check_hostname = False
_TLS.verify_mode = ssl.CERT_NONE


def api(path, method="GET", payload=None, key=""):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{BASE}{path}", data=body, method=method,
        headers={"SIGNOZ-API-KEY": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=90, context=_TLS) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as err:
        raise SystemExit(f"{path} {err.code}: {err.read().decode()[:400]}") from None
    try:
        parsed = json.loads(raw)
    except ValueError:
        # An unknown SigNoz path falls through to the single-page app, which answers
        # 200 with HTML. Treat that as the routing error it is.
        raise SystemExit(f"{path} returned non-JSON — wrong path or host?") from None
    if parsed.get("status") == "error":
        raise SystemExit(f"{path}: {json.dumps(parsed.get('error'))[:400]}")
    return parsed


def to_payload(rule):
    """Build the v2alpha1 rule body.

    ``op: '1'`` is Above and ``matchType: '1'`` is at-least-once, matching the rules
    the sibling repos already ship — keep them in step so one mental model covers the
    whole estate.
    """
    return {
        "schemaVersion": "v2alpha1",
        "alert": rule["name"],
        "alertType": rule["alert_type"],
        "ruleType": "threshold_rule",
        "disabled": False,
        "condition": {
            "selectedQueryName": "A",
            "compositeQuery": {
                "queries": [{"type": "clickhouse_sql",
                             "spec": {"name": "A", "disabled": False, "query": rule["query"]}}],
            },
            "thresholds": {
                "kind": "basic",
                "spec": [{"name": rule["severity"], "target": rule["target"],
                          "matchType": "1", "op": "1", "channels": [CHANNEL]}],
            },
        },
        "evaluation": {"kind": "rolling",
                       "spec": {"evalWindow": rule["eval_window"], "frequency": rule["frequency"]}},
        "notificationSettings": {"groupBy": [], "renotify": {"enabled": False}},
        "labels": {"severity": rule["severity"], "source": SOURCE, "managed_by": MANAGED_BY},
        "annotations": {"summary": rule["intent"], "description": rule["description"]},
    }


def window_seconds(spec):
    """Parse a Go duration of the shape SigNoz stores, e.g. "15m0s" or "6h0m0s"."""
    total, number = 0, ""
    for ch in spec:
        if ch.isdigit():
            number += ch
        else:
            total += int(number or 0) * {"h": 3600, "m": 60, "s": 1}[ch]
            number = ""
    return total


def check(rule, key):
    """Run one rule's query and report rows, and whether it would fire right now.

    The row count alone is not enough. A rule that returns rows AND exceeds its
    target is a rule that pages the moment it is applied, and "apply the rules"
    should never be a thing you do and then immediately have to explain.
    """
    # The rule's OWN window, not a convenient round hour. Checking an hour of
    # data against a rule that evaluates fifteen minutes is how "0 rule(s) would
    # page on apply" was reported for a rule that then paged within minutes: a
    # queue that is empty at some point in an hour can be non-empty for every
    # sample of the last fifteen.
    end_ms = int(time.time() * 1000)
    start_ms = end_ms - window_seconds(rule["eval_window"]) * 1000
    query = (rule["query"]
             .replace("{{.start_timestamp_nano}}", str(start_ms * 1_000_000))
             .replace("{{.end_timestamp_nano}}", str(end_ms * 1_000_000)))
    body = api("/api/v4/query_range", "POST", {
        "start": start_ms, "end": end_ms, "step": 60,
        "compositeQuery": {
            "queryType": "clickhouse_sql", "panelType": "graph",
            "chQueries": {"A": {"name": "A", "query": query, "disabled": False}},
        },
    }, key)
    series = ((body.get("data") or {}).get("result") or [{}])[0].get("series") or []
    peak = None
    for s in series:
        for point in s.get("values") or []:
            v = point.get("value")
            if v is None:
                continue
            try:
                v = float(v)
            except (TypeError, ValueError):
                continue
            peak = v if peak is None else max(peak, v)
    return len(series), peak


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="write the rules (default: report only)")
    ap.add_argument("--check", action="store_true", help="run each query and report row counts")
    args = ap.parse_args()

    key = os.environ.get("SIGNOZ_API_KEY")
    if not key:
        raise SystemExit("SIGNOZ_API_KEY is required (see the module docstring).")

    if args.check:
        firing = 0
        for rule in RULES:
            rows, peak = check(rule, key)
            shown = "-" if peak is None else f"{peak:g}"
            verdict = "ok"
            if peak is not None and peak > rule["target"]:
                verdict, firing = "WOULD FIRE", firing + 1
            print(f"{rows:>4} rows  peak={shown:>10}  target={rule['target']:<5} "
                  f"win={rule['eval_window']:<7} {verdict:<10}  {rule['name']}")
        print("\nZero rows is fine before the host has reported. An ERROR is not, and")
        print(f"neither is WOULD FIRE: {firing} rule(s) would page on apply.")
        return

    channels = [c.get("name") for c in (api("/api/v1/channels", key=key).get("data") or [])]
    if CHANNEL not in channels:
        raise SystemExit(
            f'Notification channel "{CHANNEL}" does not exist, and SigNoz refuses a rule that '
            f"names none. Only a SigNoz ADMIN can create one (Settings → Alert Channels).\n"
            f"Channels visible to this key: {', '.join(channels) or '(none)'}")

    existing = api("/api/v1/rules", key=key).get("data") or {}
    rules = existing.get("rules") if isinstance(existing, dict) else existing
    by_name = {r.get("alert") or r.get("name"): r for r in rules or []}

    created = updated = 0
    for rule in RULES:
        current = by_name.get(rule["name"])
        verb = "UPDATE" if current else "CREATE"
        if args.apply:
            payload = to_payload(rule)
            if current:
                api(f"/api/v1/rules/{current['id']}", "PUT", payload, key)
                updated += 1
            else:
                api("/api/v1/rules", "POST", payload, key)
                created += 1
        print(f"{verb:<6} {rule['name']}")

    if args.apply:
        print(f'\nDone. {created} created, {updated} updated, channel "{CHANNEL}".')
    else:
        print(f"\n{len(RULES)} rule(s) — report only. Pass --check to validate, --apply to write.")


if __name__ == "__main__":
    main()
