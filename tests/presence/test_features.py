"""Checks presence/features.json against the fleet-presence schema's rules (stdlib only, so CI needs no install)."""
import glob
import json
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ID = re.compile(r"^[a-z][a-z0-9-]*$")
FEATURE_KEYS = {"id", "name", "status", "summary", "audiences", "headline", "screens", "sources"}
REQUIRED = {"id", "name", "status", "summary", "audiences", "sources"}


class FeaturesFile(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(os.path.join(ROOT, "presence", "features.json"), encoding="utf-8") as fh:
            cls.data = json.load(fh)

    def test_top_level(self):
        self.assertEqual(set(self.data) - {"scenarios"}, {"property", "audiences", "features"})
        self.assertEqual(self.data["property"], "documenso")
        self.assertTrue(self.data["audiences"])

    def test_features(self):
        ids = [f["id"] for f in self.data["features"]]
        self.assertEqual(len(ids), len(set(ids)), "duplicate feature id")
        for f in self.data["features"]:
            self.assertTrue(REQUIRED <= set(f), f"{f.get('id')}: missing keys")
            self.assertFalse(set(f) - FEATURE_KEYS, f"{f['id']}: unknown keys")
            self.assertRegex(f["id"], ID)
            self.assertIn(f["status"], ("building", "ready"))
            self.assertLessEqual(len(f["summary"]), 160)
            self.assertNotIn("—", f["summary"], "no em dashes")
            self.assertTrue(set(f["audiences"]) <= set(self.data["audiences"]), f"{f['id']}: unknown audience")
            self.assertTrue(f["sources"])

    def test_sources_match_files(self):
        for f in self.data["features"]:
            for pattern in f["sources"]:
                self.assertTrue(glob.glob(os.path.join(ROOT, pattern), recursive=True),
                                f"{f['id']}: source {pattern} matches no file")

    def test_scenarios(self):
        ids = {f["id"] for f in self.data["features"]}
        for s in self.data.get("scenarios", []):
            self.assertRegex(s["id"], ID)
            self.assertTrue(s["features"])
            self.assertTrue(set(s["features"]) <= ids, f"{s['id']}: unknown feature")


if __name__ == "__main__":
    unittest.main()
