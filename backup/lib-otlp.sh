#!/usr/bin/env bash
# Shared OTLP emitters. Sourced, never executed.
#
# doodlessd already runs an oltp-relay (relay-gate on 127.0.0.1:18080) in front
# of an OpenTelemetry collector that ships to SigNoz. Everything below speaks
# OTLP/HTTP JSON at that relay. We are not inventing a notification channel;
# we are using the one the host already has, which means the backup shows up
# in the same place as every other signal from this box.
#
# Every function here is best-effort and MUST NOT fail the caller. A telemetry
# outage is not a backup failure, and a `set -e` script that dies because the
# relay was restarting would turn a working backup into a red timer.

# _otlp_enabled — true only if both endpoint and key are configured.
_otlp_enabled() {
  [[ -n "${OTLP_ENDPOINT:-}" && -n "${OTLP_API_KEY:-}" ]]
}

_otlp_post() {
  local path="$1" payload="$2"
  _otlp_enabled || return 0
  # --max-time so a hung relay cannot stall the run; || true so a non-zero
  # curl exit never propagates. Output discarded: the relay's answer is not
  # actionable here and would only pollute the journal.
  curl -sS --max-time 10 \
    -X POST "${OTLP_ENDPOINT%/}${path}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OTLP_API_KEY}" \
    --data-binary "$payload" >/dev/null 2>&1 || true
}

_otlp_resource() {
  cat <<JSON
{"attributes":[
  {"key":"service.name","value":{"stringValue":"doodlessd-backup"}},
  {"key":"host.name","value":{"stringValue":"$(hostname -s)"}},
  {"key":"deployment.environment","value":{"stringValue":"production"}}
]}
JSON
}

# otlp_gauge <metric.name> <int value> <unit>
#
# Emitted as a gauge, not a counter, on purpose: the value that matters is
# "when did a backup last succeed", and a gauge holding a unix timestamp lets
# SigNoz alert on `now() - backup.last_success > 36h`. That single alert catches
# the failure mode no OnFailure hook can — the timer that stopped firing at
# all, because the unit was masked, the host was down, or someone disabled it
# "just for a minute" during maintenance.
otlp_gauge() {
  local name="$1" value="$2" unit="${3:-1}"
  local now_ns
  now_ns="$(date +%s)000000000"
  _otlp_post /v1/metrics "$(cat <<JSON
{"resourceMetrics":[{
  "resource": $(_otlp_resource),
  "scopeMetrics":[{
    "scope":{"name":"doodlessd-backup"},
    "metrics":[{
      "name":"${name}",
      "unit":"${unit}",
      "gauge":{"dataPoints":[{
        "asInt":"${value}",
        "timeUnixNano":"${now_ns}"
      }]}
    }]
  }]
}]}
JSON
)"
}

# otlp_log <severityText> <severityNumber> <message>
#
# Severity numbers are the OTLP scale: 9=INFO, 13=WARN, 17=ERROR.
otlp_log() {
  local sev_text="$1" sev_num="$2" msg="$3"
  local now_ns escaped
  now_ns="$(date +%s)000000000"
  # JSON-escape the message. A restic error can contain quotes, backslashes and
  # newlines; pasting it raw produces malformed JSON that the relay rejects, so
  # the alert about the failure would itself fail.
  escaped=$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
  _otlp_post /v1/logs "$(cat <<JSON
{"resourceLogs":[{
  "resource": $(_otlp_resource),
  "scopeLogs":[{
    "scope":{"name":"doodlessd-backup"},
    "logRecords":[{
      "timeUnixNano":"${now_ns}",
      "severityNumber":${sev_num},
      "severityText":"${sev_text}",
      "body":{"stringValue":${escaped}}
    }]
  }]
}]}
JSON
)"
}
