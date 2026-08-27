import json
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from unittest.mock import patch
from urllib.error import URLError

from scripts.finalize_deployment import finalize_site
from scripts.publication_gate import (
    FRIDAY_SCHEDULE,
    compare_periods,
    expected_chart_period,
    is_scheduled_friday,
    main as publication_gate_main,
    read_live_period,
)


SOURCE_URL = "https://kworb.net/spotify/country/global_weekly.html"


class ExpectedPeriodTests(unittest.TestCase):
    def assert_period(self, timestamp: str, expected: str) -> None:
        run_at = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        self.assertEqual(expected_chart_period(run_at), date.fromisoformat(expected))

    def test_thursday_before_publication(self) -> None:
        self.assert_period("2026-08-06T18:00:00Z", "2026-07-30")

    def test_friday_after_period_changes(self) -> None:
        self.assert_period("2026-08-07T18:00:00Z", "2026-08-06")

    def test_saturday_fallback(self) -> None:
        self.assert_period("2026-08-08T18:00:00Z", "2026-08-06")

    def test_year_and_month_boundaries(self) -> None:
        self.assert_period("2027-01-01T18:00:00Z", "2026-12-31")
        self.assert_period("2026-05-01T18:00:00Z", "2026-04-30")

    def test_leap_year_boundary(self) -> None:
        self.assert_period("2024-03-01T18:00:00Z", "2024-02-29")

    def test_vancouver_date_controls_boundary(self) -> None:
        self.assert_period("2026-08-07T02:00:00Z", "2026-07-30")


class PublicationDecisionTests(unittest.TestCase):
    def decision(
        self,
        fetched: str,
        expected: str,
        live: str | None,
        *,
        defer_stale_source: bool = False,
    ):
        return compare_periods(
            date.fromisoformat(fetched),
            date.fromisoformat(expected),
            date.fromisoformat(live) if live else None,
            source_url=SOURCE_URL,
            manifest_warning="manifest unavailable" if live is None else None,
            defer_stale_source=defer_stale_source,
        )

    def test_stale_chart_rejection(self) -> None:
        decision = self.decision("2026-07-30", "2026-08-06", "2026-07-30")
        self.assertEqual((decision.status, decision.release_action), ("stale-source", "fail"))

    def test_scheduled_friday_stale_but_valid_is_deferred(self) -> None:
        decision = self.decision(
            "2026-07-30",
            "2026-08-06",
            "2026-07-30",
            defer_stale_source=True,
        )
        self.assertEqual(
            (decision.status, decision.release_action),
            ("publication-deferred", "skip"),
        )

    def test_saturday_equivalent_remains_failure(self) -> None:
        decision = self.decision("2026-07-30", "2026-08-06", "2026-07-30")
        self.assertEqual((decision.status, decision.release_action), ("stale-source", "fail"))

    def test_friday_expected_fresh_period_deploys(self) -> None:
        decision = self.decision(
            "2026-08-06",
            "2026-08-06",
            "2026-07-30",
            defer_stale_source=True,
        )
        self.assertEqual((decision.status, decision.release_action), ("newer-period", "deploy"))

    def test_friday_deferral_never_allows_older_than_live(self) -> None:
        decision = self.decision(
            "2026-07-30",
            "2026-08-06",
            "2026-08-06",
            defer_stale_source=True,
        )
        self.assertEqual((decision.status, decision.release_action), ("stale-source", "fail"))

    def test_friday_deferral_rejects_more_than_one_period_stale(self) -> None:
        decision = self.decision(
            "2026-07-23",
            "2026-08-06",
            "2026-07-23",
            defer_stale_source=True,
        )
        self.assertEqual((decision.status, decision.release_action), ("stale-source", "fail"))

    def test_same_period_no_op(self) -> None:
        decision = self.decision("2026-08-06", "2026-08-06", "2026-08-06")
        self.assertEqual((decision.status, decision.release_action), ("no-new-period", "skip"))

    def test_newer_period_deployment(self) -> None:
        decision = self.decision("2026-08-06", "2026-08-06", "2026-07-30")
        self.assertEqual((decision.status, decision.release_action), ("newer-period", "deploy"))

    def test_older_than_live_rejection(self) -> None:
        decision = self.decision("2026-08-06", "2026-08-06", "2026-08-13")
        self.assertEqual((decision.status, decision.release_action), ("older-than-live", "fail"))

    def test_missing_manifest_continues_with_warning(self) -> None:
        decision = self.decision("2026-08-06", "2026-08-06", None)
        self.assertEqual(
            (decision.status, decision.release_action, decision.warning),
            ("deploy-with-manifest-warning", "deploy", "manifest unavailable"),
        )

    def test_unreadable_manifest_returns_warning(self) -> None:
        with patch("scripts.publication_gate.urlopen", side_effect=URLError("offline")):
            live_period, warning = read_live_period("https://example.test/manifest.json")
        self.assertIsNone(live_period)
        self.assertIn("Could not read live deployment manifest", warning)

    def test_only_the_exact_scheduled_friday_trigger_enables_deferral(self) -> None:
        self.assertTrue(is_scheduled_friday("schedule", FRIDAY_SCHEDULE))
        self.assertFalse(is_scheduled_friday("schedule", "0 18 * * 6"))
        self.assertFalse(is_scheduled_friday("workflow_dispatch", FRIDAY_SCHEDULE))

    def test_scheduled_friday_deferred_cli_finishes_successfully(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch(
            "scripts.publication_gate.read_live_period",
            return_value=(date.fromisoformat("2026-07-30"), None),
        ):
            output = Path(directory) / "decision.json"
            exit_code = publication_gate_main(
                [
                    "--chart-period",
                    "2026-07-30",
                    "--source-url",
                    SOURCE_URL,
                    "--run-at",
                    "2026-08-07T22:00:00Z",
                    "--event-name",
                    "schedule",
                    "--schedule",
                    FRIDAY_SCHEDULE,
                    "--output",
                    str(output),
                ]
            )
            decision = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(exit_code, 0)
        self.assertEqual(decision["status"], "publication-deferred")
        self.assertEqual(decision["release_action"], "skip")

    def test_scheduled_saturday_stale_cli_remains_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch(
            "scripts.publication_gate.read_live_period",
            return_value=(date.fromisoformat("2026-07-30"), None),
        ):
            output = Path(directory) / "decision.json"
            exit_code = publication_gate_main(
                [
                    "--chart-period",
                    "2026-07-30",
                    "--source-url",
                    SOURCE_URL,
                    "--run-at",
                    "2026-08-08T18:00:00Z",
                    "--event-name",
                    "schedule",
                    "--schedule",
                    "0 18 * * 6",
                    "--output",
                    str(output),
                ]
            )
            decision = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(exit_code, 1)
        self.assertEqual(decision["status"], "stale-source")
        self.assertEqual(decision["release_action"], "fail")


class FinalizeDeploymentTests(unittest.TestCase):
    def test_manifest_and_page_are_stamped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            site = Path(directory)
            (site / "deployment-manifest.json").write_text(
                json.dumps({"chart_period": "2026-08-06", "deployed_at": None}),
                encoding="utf-8",
            )
            (site / "index.html").write_text(
                '<span id="site-deployed-at">pending deployment</span>',
                encoding="utf-8",
            )
            finalize_site(site, "2026-08-08T18:01:02Z", "https://example.test/run/1")
            manifest = json.loads((site / "deployment-manifest.json").read_text(encoding="utf-8"))
            page = (site / "index.html").read_text(encoding="utf-8")
            self.assertEqual(manifest["deployed_at"], "2026-08-08T18:01:02Z")
            self.assertEqual(manifest["run_url"], "https://example.test/run/1")
            self.assertIn(">2026-08-08T18:01:02Z</span>", page)


if __name__ == "__main__":
    unittest.main()
