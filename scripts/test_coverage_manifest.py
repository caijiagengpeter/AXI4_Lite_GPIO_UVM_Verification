#!/usr/bin/env python3.11
"""Directed C3.1 infrastructure self-tests; no simulator is required."""

from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import unittest

import coverage_manifest as cm


def base_plan() -> dict:
    run = {
        "id": "normal_seed1",
        "set": "gpio_dut",
        "merge_group": "gpio",
        "test_name": "normal_test",
        "target": "normal",
        "seed": 1,
        "execution_target": "GPIO DUT",
        "build_variant": "default",
        "config": "default",
        "coverage_object": "gpio_rtl",
        "driver_mode": "serial",
        "runtime_parameters": {},
        "expected_outcome": {"kind": "clean_uvm", "required_markers": []},
        "plusargs": [],
    }
    return {
        "schema_version": "1.0",
        "builds": {"default": {
            "top": "tb_top",
            "filelist": "filelist.f",
            "compile_config": "default",
            "dut_parameters": {"NIN": 5},
            "compile_options": [],
        }},
        "merge_groups": {
            "gpio": {"coverage_object": "gpio_rtl", "coverage_claim": "GPIO"}
        },
        "runs": [run],
    }


def make_db(path: Path) -> None:
    target = path / "snps" / "coverage" / "db" / "testdata" / "run"
    target.mkdir(parents=True)
    (target / "data").write_text("coverage", encoding="utf-8")


def clean_log(path: Path, extra: str = "") -> None:
    path.write_text(
        extra + "\n--- UVM Report Summary ---\n"
        "UVM_WARNING :    0\nUVM_ERROR :    0\nUVM_FATAL :    0\n",
        encoding="utf-8",
    )


class CoverageManifestTests(unittest.TestCase):
    def test_cover_incomplete_is_not_an_assertion_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            report = Path(temp)
            (report / "asserts.html").write_text(
                "Summary for Assertions</b><table>"
                "<tr><td>Total Number</td><td>1</td></tr>"
                "<tr><td>Failure</td><td>0</td></tr>"
                "<tr><td>Without Attempts</td><td>0</td></tr></table>"
                "Summary for Cover Properties</b><table>"
                "<tr><td>Total Number</td><td>1</td></tr>"
                "<tr><td>Matches</td><td>1</td></tr></table>"
                "Detail Report for Assertions</b>"
                "<tr class=\"wht\"><td class=\"lf\"><a name=\"tag_hvp_ast_a\">a</a></td>"
                "<td>0</td><td>0</td><td>10</td><td>10</td><td>0</td><td>0</td></tr>"
                "Detail Report for Cover Properties</b>"
                "<tr class=\"wht\"><td class=\"lf\"><a name=\"tag_hvp_ast_c\">c</a></td>"
                "<td>0</td><td>0</td><td>10</td><td>1</td><td>1</td><td>0</td></tr>",
                encoding="utf-8",
            )
            result = cm.parse_urg_report(report)
            self.assertEqual(result["assertion_attempts"], 10)
            self.assertEqual(result["assertion_failures"], 0)
            self.assertEqual(result["sva_cover_properties_matched"], 1)

    def test_overlay_plan_appends_runs_without_changing_base(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            base = base_plan()
            (root / "base.json").write_text(json.dumps(base), encoding="utf-8")
            added = copy.deepcopy(base["runs"][0])
            added.update({"id": "closure_seed21", "seed": 21})
            overlay = {
                "extends": "base.json",
                "phase": "AXI4-Lite v4.0-C3.2",
                "runs": [added],
            }
            (root / "overlay.json").write_text(
                json.dumps(overlay), encoding="utf-8"
            )
            resolved = cm.read_plan(root / "overlay.json")
            self.assertEqual(resolved["phase"], "AXI4-Lite v4.0-C3.2")
            self.assertEqual(
                [run["id"] for run in resolved["runs"]],
                ["normal_seed1", "closure_seed21"],
            )
            self.assertEqual(len(cm.read_plan(root / "base.json")["runs"]), 1)

    def test_missing_db_is_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            log = root / "run.log"
            clean_log(log)
            result = cm.evaluate_run(
                0, log, root / "missing.vdb", {"kind": "clean_uvm"}
            )
            self.assertEqual(result["status"], "FAIL")
            self.assertIn("missing_or_empty_coverage_db", result["reasons"])

    def test_run_failure_is_not_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            log, db = root / "run.log", root / "run.vdb"
            clean_log(log)
            make_db(db)
            result = cm.evaluate_run(17, log, db, {"kind": "clean_uvm"})
            self.assertEqual(result["status"], "FAIL")
            self.assertIn("run_exit_code=17", result["reasons"])

    def test_wrong_merge_variant_is_rejected(self) -> None:
        plan = base_plan()
        plan["builds"]["other"] = copy.deepcopy(plan["builds"]["default"])
        plan["builds"]["other"]["dut_parameters"] = {"NIN": 0}
        other = copy.deepcopy(plan["runs"][0])
        other.update({"id": "other", "build_variant": "other", "seed": 2})
        plan["runs"].append(other)
        errors, _ = cm.validate_plan(plan)
        self.assertTrue(any("mixes incompatible variants" in item for item in errors))

    def test_duplicate_seed_is_reported(self) -> None:
        plan = base_plan()
        duplicate = copy.deepcopy(plan["runs"][0])
        duplicate["id"] = "duplicate"
        plan["runs"].append(duplicate)
        errors, warnings = cm.validate_plan(plan)
        self.assertFalse(errors)
        self.assertTrue(any("duplicate seed" in item for item in warnings))

    def test_negative_expected_outcome(self) -> None:
        expected = {
            "kind": "controlled_checker_faults",
            "fault_injection": ["orphan_commit"],
            "required_markers": ["[C2_SELFTEST_PASS]", "orphan=1"],
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            log, db = root / "run.log", root / "run.vdb"
            make_db(db)
            clean_log(log)
            self.assertEqual(
                cm.evaluate_run(0, log, db, expected)["status"], "FAIL"
            )
            clean_log(log, "UVM_INFO [C2_SELFTEST_PASS] orphan=1")
            self.assertEqual(
                cm.evaluate_run(0, log, db, expected)["status"], "PASS"
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
