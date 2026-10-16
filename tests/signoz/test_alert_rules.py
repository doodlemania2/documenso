"""Pins the shape and channel of every SigNoz rule defined in scripts/signoz/.

Run: python3 -m unittest discover -s tests/signoz -v   (standard library only)

SigNoz accepts a rule whose query lacks a ``ts`` column and then never fires it,
and a name collision makes the applier overwrite a sibling rule. Both are silent,
so both are pinned. The channel is pinned because a rule that names none is
refused, and one that names the wrong channel pages the wrong audience.
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts", "signoz"))
import apply_alert_rules  # noqa: E402
from alert_rules import RULES  # noqa: E402

REQUIRED = {"name", "severity", "alert_type", "target", "eval_window",
            "frequency", "intent", "description", "query"}


class RuleShape(unittest.TestCase):
    def test_there_are_rules(self):
        self.assertGreaterEqual(len(RULES), 2)

    def test_names_unique_and_prefixed(self):
        names = [r["name"] for r in RULES]
        self.assertEqual(len(names), len(set(names)))
        for n in names:
            self.assertTrue(n.startswith("TDPdf "), n)

    def test_required_keys_and_severity(self):
        for r in RULES:
            self.assertFalse(REQUIRED - r.keys(), r["name"])
            self.assertIn(r["severity"], {"warning", "critical"}, r["name"])

    def test_every_query_returns_ts_and_value(self):
        for r in RULES:
            self.assertIn("AS ts", r["query"], r["name"])
            self.assertIn("AS value", r["query"], r["name"])
            self.assertIn("GROUP BY ts", r["query"], r["name"])

    def test_every_query_is_scoped_to_the_backup_service(self):
        for r in RULES:
            self.assertIn("'doodlessd-backup'", r["query"], r["name"])

    def test_description_carries_a_runbook(self):
        for r in RULES:
            self.assertIn("Runbook", r["description"], r["name"])

    def test_heartbeat_rule_has_a_never_reported_sentinel(self):
        q = next(r for r in RULES if "No successful backup" in r["name"])["query"]
        self.assertIn("UNION ALL", q)
        self.assertIn("9999", q)


class Channel(unittest.TestCase):
    def test_default_channel_is_ntfy_tdpdf(self):
        self.assertEqual(apply_alert_rules.CHANNEL, "ntfy-tdpdf")

    def test_payload_attaches_to_that_channel_by_name(self):
        for r in RULES:
            p = apply_alert_rules.to_payload(r)
            spec = p["condition"]["thresholds"]["spec"][0]
            self.assertEqual(spec["channels"], ["ntfy-tdpdf"], r["name"])
            self.assertEqual(p["alert"], r["name"])
            self.assertEqual(p["labels"]["severity"], r["severity"])

    def test_no_retired_channel_left_in_scripts(self):
        for fn in ("alert_rules.py", "apply_alert_rules.py"):
            text = open(os.path.join(HERE, "..", "..", "scripts", "signoz", fn)).read().lower()
            self.assertNotIn("mattermost", text, fn)


if __name__ == "__main__":
    unittest.main()
