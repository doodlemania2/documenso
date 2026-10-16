"""SigNoz alert rules for the TDPdf signing server (Documenso on doodlessd).

Everything here is written against what the host actually sends. As of 2026-10-16
that is ONLY the backup job (service.name = ``doodlessd-backup``, emitted by
backup/lib-otlp.sh through the oltp-relay). The Documenso server itself sends no
telemetry to SigNoz, so there is nothing to alert on for request errors or
availability yet; see "Gaps" in the PR notes / README rather than a rule that can
never fire.

Contract details inherited from the sibling repos (oltp-relay, stfoa-function):

* Every query MUST return a ``value`` column and a ``ts`` column, with ``ts`` the
  constant below and first in the ``GROUP BY``. Without ``ts`` the evaluator logs
  ``query result is nil`` forever and the rule looks healthy while being dead.
* Threshold ``op: '1'`` is Above and cannot be inverted, so absence is written as
  "hours since last success" compared Above a limit.
* ClickHouse returns NO rows when a ``GROUP BY`` has no input, so a rule about
  something disappearing needs a sentinel row in a ``UNION ALL``; otherwise the
  total outage the rule exists for yields an empty result and silence.
* A fingerprint subquery that is JOINed must say ``SELECT DISTINCT fingerprint``
  (time_series_v4 holds one row per series per hour).
"""

TS = "fromUnixTimestamp64Nano({{.start_timestamp_nano}}) AS ts"

SERVICE = "doodlessd-backup"

#: The heartbeat gauge. Confirmed 2026-10-16 (first real run after the relay key was
#: issued) to arrive under the dotted OTLP name. The underscore spelling is kept as a
#: harmless hedge against a pipeline that rewrites dots.
HEARTBEAT_METRICS = (
    "backup.last_success.timestamp",
    "backup_last_success_timestamp",
)

#: Hours of silence before the heartbeat rule fires. 36, not 25: one skipped day on
#: a daily schedule is a blip, two is a pattern (backup/README.md).
HEARTBEAT_MAX_HOURS = 36

#: A sentinel for "never reported" that is unmistakably above any real threshold.
NEVER_HOURS = 9999

_METRIC_LIST = ", ".join(f"'{m}'" for m in HEARTBEAT_METRICS)

RULES = [
    {
        "name": "TDPdf Backup - No successful backup in 36 hours",
        "severity": "critical",
        "alert_type": "METRIC_BASED_ALERT",
        "target": HEARTBEAT_MAX_HOURS,
        # Reads 14 days back regardless of the evaluation window: the gauge is emitted
        # once a day, so the rule's own window (1h) would never contain a sample.
        "eval_window": "1h0m0s",
        "frequency": "30m0s",
        "intent": "doodlessd has not reported a successful backup for over 36 hours",
        "description": (
            "Dead-man's switch. The backup job emits backup.last_success.timestamp only after a "
            "complete run, so this fires for every way a backup can stop: failing, masked or "
            "disabled timer, host down, or telemetry broken. It ALSO fires if the heartbeat has "
            "never arrived (value 9999), which is the state until OTLP_API_KEY is set in "
            "/etc/doodlessd-backup/backup.env and the timers are enabled. "
            "Runbook, on doodlessd: `systemctl list-timers 'doodlessd-*'`, "
            "`journalctl -u doodlessd-backup.service -n 80`, then run "
            "`sudo systemctl start doodlessd-backup.service` by hand. If the run succeeds but this "
            "stays red, the telemetry path is broken: check OTLP_API_KEY and relay-gate on :18080."
        ),
        "query": f"""SELECT {TS},
       toInt64(if(countIf(m = 1) = 0, {NEVER_HOURS},
                  (toUnixTimestamp(now()) - maxIf(unix_milli, m = 1) / 1000) / 3600)) AS value
FROM (
  SELECT s.unix_milli AS unix_milli, 1 AS m
  FROM signoz_metrics.distributed_samples_v4 AS s
  INNER JOIN (
    SELECT DISTINCT fingerprint
    FROM signoz_metrics.time_series_v4
    WHERE metric_name IN ({_METRIC_LIST})
      AND JSONExtractString(labels, 'service.name') = '{SERVICE}'
  ) AS t ON s.fingerprint = t.fingerprint
  WHERE s.metric_name IN ({_METRIC_LIST})
    AND s.unix_milli >= (toUnixTimestamp(now()) - 14 * 86400) * 1000
  UNION ALL
  SELECT 0 AS unix_milli, 0 AS m
)
GROUP BY ts""",
    },
    {
        "name": "TDPdf Backup - A backup or prune run failed",
        "severity": "critical",
        "alert_type": "LOGS_BASED_ALERT",
        # No sentinel: no ERROR rows means nothing failed, and an empty result is the
        # healthy state for this rule (the dead-man's switch above covers silence).
        "target": 0,
        "eval_window": "1h0m0s",
        "frequency": "15m0s",
        "intent": "a doodlessd backup or prune run logged an ERROR",
        "description": (
            "Emitted by the in-script ERR trap and by the systemd OnFailure handler, so it also "
            "covers OOM kills and timeouts. The log body names the failing step and carries the "
            "last lines of restic output. Runbook, on doodlessd: "
            "`journalctl -u doodlessd-backup.service -u doodlessd-prune.service -n 80`. "
            "A failed backup is a real gap in recovery points: re-run by hand once the cause is fixed."
        ),
        "query": f"""SELECT {TS},
       toInt32(count()) AS value
FROM signoz_logs.distributed_logs_v2
WHERE timestamp >= {{{{.start_timestamp_nano}}}} AND timestamp <= {{{{.end_timestamp_nano}}}}
  AND resources_string['service.name'] = '{SERVICE}'
  AND upper(severity_text) = 'ERROR'
GROUP BY ts""",
    },
]
