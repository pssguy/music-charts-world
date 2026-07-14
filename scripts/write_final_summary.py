#!/usr/bin/env python3

import os
from datetime import date, datetime, timezone


def value(name: str, fallback: str = "not available") -> str:
    return os.environ.get(name, "").strip() or fallback


def chart_period_label() -> str:
    raw = value("CHART_PERIOD")
    try:
        period = date.fromisoformat(raw)
    except ValueError:
        return raw
    return f"Chart week ending {period.strftime('%B')} {period.day}, {period.year} ({raw})"


stages = {
    "Prepare": value("PREPARE_RESULT", "not run"),
    "Fetch and validate": value("FETCH_RESULT", "not run"),
    "Render": value("RENDER_RESULT", "not run"),
    "Test": value("TEST_RESULT", "not run"),
    "Deploy": value("DEPLOY_RESULT", "not run"),
}
failed = [
    name
    for name, result in stages.items()
    if result in {"failure", "cancelled", "timed_out"}
]
next_actions = {
    "Prepare": "Correct the release configuration or missing project file, then rerun the workflow.",
    "Fetch and validate": "Review the critical validation rules and affected markets; rerun only after the source or parser issue is understood.",
    "Render": "Inspect the Quarto log and output-size diagnostics, then fix or rerun the render.",
    "Test": "Inspect the failed generated-site or HTTP assertion before approving publication.",
    "Deploy": "Check the github-pages environment, Pages settings, and deployment log; the tested artifact may be rerun after the platform issue is resolved.",
}
if stages["Deploy"] == "success":
    outcome = "Deployment completed"
elif failed:
    outcome = f"Stopped at {failed[0]}"
else:
    outcome = "Deployment did not run"

lines = [
    "# MusicCharts.world weekly publication",
    "",
    f"**Outcome:** {outcome}",
    "",
    "## Chart issue",
    "",
    f"- Chart period: {chart_period_label()}",
    f"- Fetched at: {value('FETCHED_AT')}",
    f"- Configured markets: {value('CONFIGURED_COUNT')}",
    f"- Configured market names: {value('CONFIGURED_NAMES')}",
    f"- Successful markets: {value('SUCCESSFUL_COUNT')} — {value('SUCCESSFUL_NAMES', 'none')}",
    f"- Failed markets: {value('FAILED_COUNT')} — {value('FAILED_NAMES', 'none')}",
    f"- Unavailable markets: {value('UNAVAILABLE_COUNT')} — {value('UNAVAILABLE_NAMES', 'none')}",
    f"- Worldwide rows: {value('WORLDWIDE_ROW_COUNT')}",
    f"- Warnings: {value('WARNING_COUNT')}",
    f"- Warning details: {value('WARNING_MESSAGES', 'none')}",
    f"- Critical failures: {value('CRITICAL_FAILURE_COUNT')}",
    f"- Failed validation rules: {value('CRITICAL_FAILURES', 'none')}",
    f"- Validation: {value('VALIDATION_STATUS')}",
    "",
    "## Gates",
    "",
    "| Stage | Result |",
    "|---|---|",
    *[f"| {name} | {result} |" for name, result in stages.items()],
    "",
    "## Rendered output",
    "",
    f"- Site bytes: {value('SITE_BYTES')}",
    f"- index.html bytes: {value('INDEX_BYTES')}",
    f"- Files: {value('FILE_COUNT')}",
    f"- Render-size warnings: {value('RENDER_WARNING_COUNT')}",
    f"- Commit: {value('DEPLOYED_COMMIT')}",
]

if stages["Deploy"] == "success":
    lines += [
        "",
        "## Publication",
        "",
        f"- Page URL: {value('PAGE_URL')}",
        f"- Deployed at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ]
else:
    lines += [
        "",
        "The Pages deployment gate was not completed, so the previously published site remains unchanged.",
        "",
        f"**Recommended next action:** {next_actions.get(failed[0], 'Review the first incomplete gate and rerun after it is resolved.') if failed else 'Review why the deployment gate was skipped.'}",
    ]

summary = "\n".join(lines) + "\n"
summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "").strip()
if summary_path:
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write(summary)
else:
    print(summary, end="")
