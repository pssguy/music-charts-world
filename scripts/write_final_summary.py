#!/usr/bin/env python3

import os
from datetime import date, datetime, timezone


def value(name: str, fallback: str = "not available") -> str:
    return os.environ.get(name, "").strip() or fallback


def period_label(raw: str) -> str:
    try:
        period = date.fromisoformat(raw)
    except ValueError:
        return raw
    return f"Chart week ending {period.strftime('%B')} {period.day}, {period.year} ({raw})"


stages = {
    "Prepare": value("PREPARE_RESULT", "not run"),
    "Fetch, validate, and publication gate": value("FETCH_RESULT", "not run"),
    "Render": value("RENDER_RESULT", "not run"),
    "Test": value("TEST_RESULT", "not run"),
    "Deploy": value("DEPLOY_RESULT", "not run"),
}
failed = [
    name
    for name, result in stages.items()
    if result in {"failure", "cancelled", "timed_out"}
]
publication_status = value("PUBLICATION_STATUS")
release_action = value("RELEASE_ACTION")

if publication_status == "no-new-period":
    outcome = "No new chart period; deployment correctly skipped"
elif publication_status == "stale-source":
    outcome = "Stale source blocked publication"
elif publication_status == "older-than-live":
    outcome = "Older-than-live chart blocked publication"
elif stages["Deploy"] == "success":
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
    "## Publication decision",
    "",
    f"- Status: {publication_status}",
    f"- Release action: {release_action}",
    f"- Fetched chart period: {period_label(value('CHART_PERIOD'))}",
    f"- Expected chart period: {value('EXPECTED_PERIOD')} (America/Vancouver calendar)",
    f"- Previously live chart period: {value('LIVE_PERIOD')}",
    f"- Source URL: {value('SOURCE_URL')}",
    f"- Live-manifest warning: {value('MANIFEST_WARNING', 'none')}",
    "",
    "## Source validation",
    "",
    f"- Data fetched at: {value('FETCHED_AT')}",
    f"- Configured markets: {value('CONFIGURED_COUNT')}",
    f"- Configured market names: {value('CONFIGURED_NAMES')}",
    f"- Successful markets: {value('SUCCESSFUL_COUNT')} - {value('SUCCESSFUL_NAMES', 'none')}",
    f"- Failed markets: {value('FAILED_COUNT')} - {value('FAILED_NAMES', 'none')}",
    f"- Unavailable markets: {value('UNAVAILABLE_COUNT')} - {value('UNAVAILABLE_NAMES', 'none')}",
    f"- Worldwide rows: {value('WORLDWIDE_ROW_COUNT')}",
    f"- Warnings: {value('WARNING_COUNT')}",
    f"- Warning details: {value('WARNING_MESSAGES', 'none')}",
    f"- Critical failures: {value('CRITICAL_FAILURE_COUNT')}",
    f"- Failed validation rules: {value('CRITICAL_FAILURES', 'none')}",
    f"- Structural validation: {value('VALIDATION_STATUS')}",
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
    f"- Git commit: {value('DEPLOYED_COMMIT')}",
    f"- GitHub Actions run: {value('RUN_URL')}",
]

if stages["Deploy"] == "success":
    lines += [
        "",
        "## Publication",
        "",
        f"- Page URL: {value('PAGE_URL')}",
        f"- Site deployed at: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ]
elif publication_status == "no-new-period":
    lines += [
        "",
        "The fetched chart period already matches the live manifest. The tested live site remains unchanged.",
    ]
else:
    next_action = {
        "stale-source": "Wait for the source to publish the expected chart period, then start a fresh workflow run.",
        "older-than-live": "Investigate the source and live manifest before any further publication attempt.",
    }.get(
        publication_status,
        "Review the first incomplete gate and rerun only after it is resolved.",
    )
    lines += [
        "",
        "The Pages deployment gate was not completed, so the previously published site remains unchanged.",
        "",
        f"**Recommended next action:** {next_action}",
    ]

summary = "\n".join(lines) + "\n"
summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "").strip()
if summary_path:
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write(summary)
else:
    print(summary, end="")
