import re
import unittest
from pathlib import Path


class WeeklyHistoryWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = Path(".github/workflows/render-deploy.yml").read_text(encoding="utf-8")
        cls.fetch = cls.workflow.split("  fetch_validate:\n", 1)[1].split("  store_history:\n", 1)[0]
        cls.store = cls.workflow.split("  store_history:\n", 1)[1].split("  render_primary:\n", 1)[0]

    def test_passed_validation_stores_even_when_publication_gate_fails_or_skips(self):
        self.assertIn("needs: fetch_validate", self.store)
        guard = next(line for line in self.store.splitlines() if line.strip().startswith("if:"))
        self.assertIn("always()", guard)
        self.assertIn("needs.fetch_validate.outputs.validation_status == 'pass'", guard)
        self.assertNotIn("release_action", self.store)
        self.assertNotIn("needs.fetch_validate.result == 'success'", self.store)

    def test_history_artifact_is_uploaded_before_the_publication_gate(self):
        upload = self.fetch.split("      - name: Upload validated weekly history", 1)[1].split(
            "      - name: Check chart freshness", 1
        )[0]
        self.assertIn("always()", upload)
        self.assertIn("steps.fetch.outputs.validation_status == 'pass'", upload)
        self.assertIn("path: staging/input/history/", upload)
        self.assertIn("chart-history-${{ github.run_id }}-${{ github.run_attempt }}", upload)
        self.assertNotIn("release_action", upload)
        self.assertIn("needs.fetch_validate.outputs.history_artifact_name", self.store)
        self.assertNotIn("validated_artifact_name", self.store)

    def test_data_is_the_only_push_target_and_only_writer_job(self):
        self.assertEqual(self.workflow.count("contents: write"), 1)
        self.assertIn("contents: write", self.store)
        pushes = re.findall(r"(?m)^\s*git push (.*)$", self.workflow)
        self.assertEqual(pushes, ["origin HEAD:refs/heads/data"])
        self.assertIn('test "$(git branch --show-current)" = data', self.store)
        self.assertIn("git checkout --orphan data", self.store)
        self.assertIn('if [ "$status" -ne 2 ]; then exit "$status"; fi', self.store)
        self.assertIn("group: chart-history-data", self.store)
        self.assertIn("branches: [main]", self.workflow)
        self.assertIn("cannot retrigger", self.store)

    def test_existing_period_exits_before_copy_commit_or_push(self):
        skip = self.store.index('if [ -d "$folder" ]; then')
        exit_position = self.store.index("exit 0", skip)
        self.assertLess(exit_position, self.store.index("cp -R"))
        self.assertLess(exit_position, self.store.index("git commit"))
        self.assertLess(exit_position, self.store.index("git push"))
        self.assertIn('test -s "$source_folder/charts.csv.gz"', self.store)
        self.assertIn('test -s "$source_folder/markets.csv"', self.store)


if __name__ == "__main__":
    unittest.main()
