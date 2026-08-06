#!/usr/bin/env python3

"""Decide whether a validated chart period should be published."""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo


PUBLICATION_TIMEZONE = ZoneInfo("America/Vancouver")
DEFAULT_MANIFEST_URL = "https://musiccharts.world/deployment-manifest.json"


@dataclass(frozen=True)
class PublicationDecision:
    status: str
    release_action: str
    fetched_period: str
    expected_period: str
    live_period: str | None
    source_url: str
    manifest_url: str
    warning: str | None = None


def expected_chart_period(run_at: datetime) -> date:
    """Return the chart Thursday expected for a publication run."""
    if run_at.tzinfo is None:
        raise ValueError("run_at must include a timezone")
    local_date = run_at.astimezone(PUBLICATION_TIMEZONE).date()
    weekday = local_date.weekday()  # Monday=0, Thursday=3, Sunday=6
    if weekday == 3:
        days_back = 7
    elif weekday < 3:
        days_back = weekday + 4
    else:
        days_back = weekday - 3
    return date.fromordinal(local_date.toordinal() - days_back)


def compare_periods(
    fetched_period: date,
    expected_period: date,
    live_period: date | None,
    *,
    source_url: str,
    manifest_url: str = DEFAULT_MANIFEST_URL,
    manifest_warning: str | None = None,
) -> PublicationDecision:
    common = {
        "fetched_period": fetched_period.isoformat(),
        "expected_period": expected_period.isoformat(),
        "live_period": live_period.isoformat() if live_period else None,
        "source_url": source_url,
        "manifest_url": manifest_url,
        "warning": manifest_warning,
    }
    if fetched_period < expected_period:
        return PublicationDecision(
            status="stale-source",
            release_action="fail",
            **common,
        )
    if live_period is None:
        return PublicationDecision(
            status="deploy-with-manifest-warning",
            release_action="deploy",
            **common,
        )
    if fetched_period == live_period:
        return PublicationDecision(
            status="no-new-period",
            release_action="skip",
            **common,
        )
    if fetched_period < live_period:
        return PublicationDecision(
            status="older-than-live",
            release_action="fail",
            **common,
        )
    return PublicationDecision(
        status="newer-period",
        release_action="deploy",
        **common,
    )


def read_live_period(manifest_url: str, timeout: float = 15) -> tuple[date | None, str | None]:
    request = Request(
        manifest_url,
        headers={"User-Agent": "MusicCharts.world publication gate"},
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload: Any = json.load(response)
        raw_period = payload.get("chart_period") if isinstance(payload, dict) else None
        if not isinstance(raw_period, str):
            raise ValueError("chart_period is missing")
        return date.fromisoformat(raw_period), None
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError, ValueError, OSError) as exc:
        return None, f"Could not read live deployment manifest: {exc}"


def write_github_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT", "").strip()
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value.replace(chr(10), ' ').replace(chr(13), ' ')}\n")


def append_summary(decision: PublicationDecision) -> None:
    live = decision.live_period or "unavailable"
    lines = [
        "## Publication freshness gate",
        "",
        f"- Status: **{decision.status}**",
        f"- Fetched chart period: {decision.fetched_period}",
        f"- Expected chart period: {decision.expected_period} (America/Vancouver calendar)",
        f"- Previously live chart period: {live}",
        f"- Source URL: {decision.source_url}",
        f"- Release action: {decision.release_action}",
    ]
    if decision.warning:
        lines.append(f"- Warning: {decision.warning}")
    summary = "\n".join(lines) + "\n"
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "").strip()
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(summary)
    else:
        print(summary, end="")


def parse_run_at(raw: str | None) -> datetime:
    if not raw:
        return datetime.now(timezone.utc)
    parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("--run-at must include a timezone")
    return parsed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--chart-period", required=True)
    parser.add_argument("--source-url", required=True)
    parser.add_argument("--manifest-url", default=DEFAULT_MANIFEST_URL)
    parser.add_argument("--run-at")
    parser.add_argument(
        "--output",
        default=str(Path("staging") / "input" / "publication-decision.json"),
    )
    args = parser.parse_args(argv)

    fetched_period = date.fromisoformat(args.chart_period)
    expected_period = expected_chart_period(parse_run_at(args.run_at))
    live_period, warning = read_live_period(args.manifest_url)
    decision = compare_periods(
        fetched_period,
        expected_period,
        live_period,
        source_url=args.source_url,
        manifest_url=args.manifest_url,
        manifest_warning=warning,
    )

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(asdict(decision), indent=2) + "\n", encoding="utf-8")

    for name, value in {
        "expected_period": decision.expected_period,
        "live_period": decision.live_period or "unavailable",
        "publication_status": decision.status,
        "release_action": decision.release_action,
        "manifest_warning": decision.warning or "",
    }.items():
        write_github_output(name, value)
    append_summary(decision)
    return 1 if decision.release_action == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
