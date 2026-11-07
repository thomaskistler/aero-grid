# SPDX-License-Identifier: GPL-2.0-only

import copy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import instruction_snapshot as snapshot


class InstructionSnapshotTests(unittest.TestCase):
    def row(self, **changes):
        row = dict(kind="task", name="test", stage="run", grant=1, n=5,
                   min=100, max=200, failures=0, minScenario="cheap", maxScenario="work")
        row.update(changes)
        return row

    def data(self):
        row = self.row()
        key = snapshot.observation_key(row)
        observations = {environment: {key: copy.deepcopy(row)} for environment in ("mock", "native")}
        data = {"estimates": {"tasks": {"test": {"run": {"fixed": 0, "perUnit": 220}}},
                              "bounds": {}},
                "record": {"schema": 1, "deferred": {}, "observations": copy.deepcopy(observations)}}
        return data, observations, {key}

    def test_target_exact_rounding(self):
        for maximum in range(15001):
            value = snapshot.target(maximum)
            self.assertEqual(value % 10, 0)
            self.assertGreaterEqual(value * 10, maximum * 11)
            if value:
                self.assertLess((value - 10) * 10, maximum * 11)
        self.assertEqual(snapshot.target(100), 110)
        self.assertEqual(snapshot.target(101), 120)

    def test_strict_spread_thresholds(self):
        self.assertFalse(snapshot.spread(400, 700))  # difference == 300
        self.assertFalse(snapshot.spread(800, 1200))  # ratio == 1.5
        self.assertTrue(snapshot.spread(799, 1200))
        self.assertTrue(snapshot.spread(0, 301))
        self.assertFalse(snapshot.spread(0, 300))

    def test_measured_incremental_growth_fitting(self):
        # Raw maxima yielding conservative targets 300, 500 and 700.
        self.assertEqual(snapshot.fit({1: 270, 2: 450, 3: 630}),
                         {"fixed": 100, "perUnit": 200})
        grants = {1: 103, 2: 302, 3: 310, 4: 450}
        fitted = snapshot.fit(grants)
        for grant, maximum in grants.items():
            self.assertGreaterEqual(fitted["fixed"] + fitted["perUnit"] * grant, snapshot.target(maximum))
        self.assertGreater(fitted["perUnit"], 0)
        self.assertEqual(snapshot.fit({1: 100}), {"fixed": 0, "perUnit": 110})
        with self.assertRaises(ValueError):
            snapshot.fit({2: 100})

    def test_ten_samples_combined_not_per_environment(self):
        data, observations, required = self.data()
        self.assertEqual(snapshot.check(data, observations, required), [])
        next(iter(observations["native"].values()))["n"] = 4
        self.assertTrue(any("combined samples" in finding for finding in snapshot.check(data, observations, required)))

    def test_any_increase_fails_and_update_does_not_hide_safety(self):
        data, observations, required = self.data()
        row = next(iter(observations["native"].values()))
        row["max"] = 201
        self.assertTrue(any("regression:" in finding for finding in snapshot.check(data, observations, required)))
        self.assertEqual(snapshot.check(data, observations, required, updating=True), [])
        row["max"] = 15001
        findings = snapshot.check(data, observations, required, updating=True)
        for category in ("safety:", "runtime:", "efficiency:"):
            self.assertTrue(any(category in finding for finding in findings))

    def test_missing_environment_entry_and_behavior_fail(self):
        data, observations, required = self.data()
        observations["native"] = {}
        self.assertTrue(any("mock AND native" in finding for finding in snapshot.check(data, observations, required)))
        observations["mock"] = {}
        self.assertTrue(any("coverage: missing" in finding for finding in snapshot.check(data, observations, required)))
        data, observations, required = self.data()
        next(iter(observations["mock"].values()))["failures"] = 1
        self.assertTrue(any("behavior:" in finding for finding in snapshot.check(data, observations, required)))

    def test_merge_keeps_noops_and_environment_extrema(self):
        rows = snapshot.merge_observations([self.row(), self.row(min=1, max=99, n=10)])
        row = next(iter(rows.values()))
        self.assertEqual((row["n"], row["min"], row["max"]), (15, 1, 200))
        with self.assertRaises(ValueError):
            snapshot.merge_observations([self.row(n=0)])

    def test_expected_errors_remain_observations(self):
        data, observations, required = self.data()
        row = next(iter(observations["mock"].values()))
        row["failures"] = row["expectedFailures"] = 2
        self.assertEqual(snapshot.check(data, observations, required), [])
        merged = snapshot.merge_observations([row, row])
        self.assertEqual(next(iter(merged.values()))["expectedFailures"], 4)

    def test_proposal_uses_higher_environment_maximum(self):
        data, observations, required = self.data()
        next(iter(observations["native"].values()))["max"] = 210
        candidate = snapshot.propose(data, observations, {"test|run": 1}, required)
        self.assertEqual(candidate["tasks"]["test"]["run"], {"fixed": 0, "perUnit": 240})
        self.assertEqual(data["estimates"]["tasks"]["test"]["run"]["perUnit"], 220)
        with self.assertRaises(ValueError):
            snapshot.propose(data, observations, {"test|run": 1}, required | {"task|test|run|2"})

    def test_atomic_write_and_radio_safe_roundtrip(self):
        data, _, _ = self.data()
        data["record"]["provenance"] = {'quoted"key': "first\nsecond"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "snapshot.lua"
            path.write_text("original")
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            snapshot.write(**data, path=path, expected_sha=sha)
            self.assertEqual(snapshot.load(path), data)
            before = path.read_bytes()
            with self.assertRaises(RuntimeError):
                snapshot.write(**data, path=path, expected_sha=sha)
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(len(list(Path(directory).iterdir())), 1)
            data["record"]["overflow"] = 2147483648
            with self.assertRaises(ValueError):
                snapshot.render(**data)
            self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
