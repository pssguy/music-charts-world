import json
import tempfile
import unittest
from datetime import date, datetime, timezone
from pathlib import Path
from unittest.mock import patch
from urllib.error import URLError

from scripts.finalize_deployment import finalize_site
from scripts.publication_gate import compare_periods, expected_chart_period, read_live_period


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
    def decision(self, fetched: str, expected: str, live: str | None):
        return compare_periods(
            date.fromisoformat(fetched),
            date.fromisoformat(expected),
            date.fromisoformat(live) if live else None,
            source_url=SOURCE_URL,
            manifest_warning="manifest unavailable" if live is None else None,
        )

    def test_stale_chart_rejection(self) -> None:
        decision = self.decision("2026-07-30", "2026-08-06", "2026-07-30")
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
