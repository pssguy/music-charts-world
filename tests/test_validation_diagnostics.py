import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.validation_diagnostics import finalize, initialize, write_json


class DiagnosticPreservationTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": ""})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_cli_blocks_missing_report_even_if_fetch_claimed_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            process = subprocess.run([
                sys.executable, "scripts/validation_diagnostics.py", "finalize",
                "--directory", tmp, "--fetch-outcome", "success", "--gate-outcome", "success",
            ], capture_output=True, text=True)
            self.assertEqual(process.returncode, 1)
            self.assertTrue((Path(tmp) / "validation-report.json").exists())

    def test_setup_failure_has_all_sources_and_blocked_decision(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            directory = Path(tmp)
            initialize(directory)
            report = finalize(directory, "skipped", "skipped")
            decision = json.loads((directory / "publication-decision.json").read_text())
            self.assertEqual(len(report["market_statuses"]), 55)
            self.assertEqual(report["worldwide_status"]["code"], "GLOBAL")
            self.assertEqual(report["validation"]["status"], "fail")
            self.assertEqual(decision["status"], "validation-blocked")
            self.assertEqual(decision["release_action"], "fail")
            for row in report["market_statuses"]:
                self.assertTrue(row["source_url"].endswith("_weekly.html"))
                self.assertEqual(row["attempts"], 0)
                self.assertTrue(row["errors"])

    def test_interrupted_fetch_preserves_completed_and_inflight_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            directory = Path(tmp)
            initialize(directory)
            path = directory / "validation-report.json"
            report = json.loads(path.read_text())
            report["market_statuses"][0].update(status="success", attempts=1, chart_period="2026-09-24")
            report["market_statuses"][1].update(attempts=2, failure_type="not_completed")
            write_json(path, report)
            result = finalize(directory, "cancelled", "skipped")
            self.assertEqual(result["market_statuses"][0]["status"], "success")
            self.assertEqual(result["market_statuses"][1]["attempts"], 2)
            self.assertEqual(result["validation"]["status"], "fail")

    def test_real_freshness_decision_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            directory = Path(tmp)
            initialize(directory)
            path = directory / "publication-decision.json"
            decision = dict(status="stale-source", release_action="fail")
            write_json(path, decision)
            finalize(directory, "success", "failure")
            self.assertEqual(json.loads(path.read_text()), decision)

    def test_gate_crash_has_explicit_failure_decision(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            directory = Path(tmp)
            initialize(directory)
            finalize(directory, "success", "failure")
            decision = json.loads((directory / "publication-decision.json").read_text())
            self.assertEqual(decision["status"], "publication-gate-error")
            self.assertEqual(decision["release_action"], "fail")

    def test_missing_report_is_recovered_and_summary_includes_source_and_policy(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            directory = Path(tmp)
            summary = directory / "summary.md"
            with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                report = finalize(directory, "failure", "skipped")
            text = summary.read_text(encoding="utf-8")
            self.assertIn("india-stale-only-v1", text)
            self.assertIn("in_weekly.html", text)
            self.assertIn("missing or unreadable", report["critical_failures"][0])


class WorkflowDiagnosticTests(unittest.TestCase):
    def test_report_survives_failure_without_allowing_render(self):
        workflow = Path(".github/workflows/render-deploy.yml").read_text(encoding="utf-8")
        fetch = workflow.split("  fetch_validate:")[1].split("  store_history:")[0]
        self.assertLess(fetch.index("validation_diagnostics.py init"), fetch.index("setup-r@"))
        self.assertLess(fetch.index("validation_diagnostics.py finalize"), fetch.index("Upload validation report"))
        self.assertEqual(fetch.count("if: ${{ always() }}"), 3)
        self.assertEqual(fetch.count("retention-days: 30"), 3)
        self.assertNotIn("if-no-files-found: warn", fetch)
        self.assertNotIn("continue-on-error", fetch)
        self.assertIn("timeout-minutes: 20", fetch)
        self.assertIn("success() && steps.publication_gate.outputs.release_action == 'deploy'", fetch)


if __name__ == "__main__":
    unittest.main()
