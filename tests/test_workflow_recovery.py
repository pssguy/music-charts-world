import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.select_render_candidate import (
    RenderCandidate,
    fallback_eligible,
    main as select_candidate_main,
    select_candidate,
)


WORKFLOW = Path(".github/workflows/render-deploy.yml")


def candidate(renderer: str, ready: bool) -> RenderCandidate:
    return RenderCandidate(
        renderer=renderer,
        ready=ready,
        artifact_name=f"site-candidate-{renderer}-123-1" if ready else "",
    )


class RenderRecoveryPolicyTests(unittest.TestCase):
    def test_primary_success_skips_fallback_and_selects_primary(self) -> None:
        self.assertFalse(fallback_eligible(primary_ready=True, workflow_cancelled=False))
        selected = select_candidate(candidate("primary", True), candidate("fallback", False))
        self.assertEqual(selected.renderer, "primary")

    def test_primary_failure_or_job_interruption_makes_fallback_eligible(self) -> None:
        self.assertTrue(fallback_eligible(primary_ready=False, workflow_cancelled=False))

    def test_explicit_workflow_cancel_blocks_fallback(self) -> None:
        self.assertFalse(fallback_eligible(primary_ready=False, workflow_cancelled=True))

    def test_fallback_success_selects_fallback_for_site_tests(self) -> None:
        selected = select_candidate(candidate("primary", False), candidate("fallback", True))
        self.assertEqual(selected.renderer, "fallback")
        self.assertTrue(selected.ready)

    def test_both_render_attempts_failing_blocks_tests_and_deployment(self) -> None:
        with self.assertRaisesRegex(ValueError, "found 0"):
            select_candidate(candidate("primary", False), candidate("fallback", False))

    def test_two_successful_candidates_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "found 2"):
            select_candidate(candidate("primary", True), candidate("fallback", True))

    def test_selector_cli_exports_the_fallback_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output.txt"
            summary = Path(directory) / "summary.md"
            with patch.dict(
                os.environ,
                {"GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)},
            ):
                exit_code = select_candidate_main(
                    [
                        "--primary-ready",
                        "false",
                        "--fallback-ready",
                        "true",
                        "--fallback-artifact",
                        "site-candidate-fallback-123-1",
                    ]
                )
            exported = output.read_text(encoding="utf-8")
            rendered_summary = summary.read_text(encoding="utf-8")
        self.assertEqual(exit_code, 0)
        self.assertIn("renderer=fallback", exported)
        self.assertIn("artifact_name=site-candidate-fallback-123-1", exported)
        self.assertIn("Successful candidate source: **fallback**", rendered_summary)


class WorkflowStructureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_schedule_and_manual_push_triggers(self) -> None:
        self.assertIn('cron: "0 22 * * 5"', self.workflow)
        self.assertIn('cron: "0 18 * * 6"', self.workflow)
        self.assertIn("  push:\n", self.workflow)
        self.assertIn("  workflow_dispatch:\n", self.workflow)

    def test_two_separate_render_jobs_use_one_validated_input(self) -> None:
        self.assertEqual(self.workflow.count("Rscript scripts/fetch_validate.R"), 1)
        self.assertIn("  render_primary:", self.workflow)
        self.assertIn("  render_fallback:", self.workflow)
        self.assertEqual(
            self.workflow.count("needs.fetch_validate.outputs.validated_artifact_name"),
            3,
        )
        self.assertNotIn("quarto render ||", self.workflow)

    def test_fallback_guard_handles_failed_need_but_respects_workflow_cancel(self) -> None:
        self.assertIn("always() &&", self.workflow)
        self.assertIn("!cancelled() &&", self.workflow)
        self.assertIn(
            "needs.render_primary.outputs.candidate_ready != 'true'",
            self.workflow,
        )

    def test_exactly_one_pages_deployment_exists_after_site_tests(self) -> None:
        self.assertEqual(self.workflow.count("actions/deploy-pages@"), 1)
        self.assertIn("needs: [fetch_validate, render_candidate, test]", self.workflow)
        self.assertIn("needs.test.result == 'success'", self.workflow)

    def test_candidate_artifacts_are_distinct_and_selected_by_output(self) -> None:
        self.assertIn("site-candidate-primary-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}", self.workflow)
        self.assertIn("site-candidate-fallback-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}", self.workflow)
        self.assertGreaterEqual(
            self.workflow.count("needs.render_candidate.outputs.artifact_name"),
            2,
        )
        self.assertEqual(
            self.workflow.count("candidate_ready: ${{ steps.candidate.outputs.ready }}"),
            2,
        )

    def test_reused_upstream_artifacts_are_consumed_by_recorded_name(self) -> None:
        self.assertIn(
            "validated_input=validated-input-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}",
            self.workflow,
        )
        self.assertNotIn(
            "name: validated-input-${{ github.run_id }}-${{ github.run_attempt }}",
            self.workflow,
        )
        self.assertEqual(
            self.workflow.count("name: ${{ needs.fetch_validate.outputs.validated_artifact_name }}"),
            3,
        )


if __name__ == "__main__":
    unittest.main()
