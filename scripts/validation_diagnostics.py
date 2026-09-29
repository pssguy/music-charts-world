#!/usr/bin/env python3
"""Keep diagnostics available even when R setup, fetching, or the gate fails."""

import argparse
import json
import os
import re
import sys
from pathlib import Path


POLICY = "india-stale-only-v1: GLOBAL and all other 54 national markets are required. Only structurally valid stale India may be unavailable for this period, with zero contribution to calculations and rankings. No stale fallback; India is fetched every run and restored automatically when current and valid."


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def initialize(directory):
    source = Path("R/fetch_charts.R").read_text(encoding="utf-8")
    vector = source.split("WORLD_MUSIC_WATCH_COUNTRIES <- c(", 1)[1]
    codes = [code.upper() for code in re.findall(r'"([a-z]{2})"', vector)]
    def pending(code):
        return dict(code=code, status="pending", failure_type="not_started",
                    source_url=f"https://kworb.net/spotify/country/{code.lower()}_weekly.html",
                    attempts=0, attempt_history=[], chart_period=None,
                    errors=["Source fetch has not started; inspect setup/fetch step outcome."])
    report = dict(schema_version="2.0", complete=False, coverage_policy=POLICY,
                  configured_markets=codes, worldwide_status=pending("GLOBAL"),
                  market_statuses=[pending(code) for code in codes],
                  validation=dict(status="fail"),
                  critical_failures=["Source validation has not completed."])
    write_json(directory / "validation-report.json", report)
    write_json(directory / "publication-decision.json", dict(
        status="validation-not-completed", release_action="fail",
        reason="Publication gate has not run; source validation is required."))


def finalize(directory, fetch_outcome, gate_outcome):
    path = directory / "validation-report.json"
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        initialize(directory)
        report = json.loads(path.read_text(encoding="utf-8"))
        report["critical_failures"] = ["Validation report missing or unreadable; consult runner logs."]
    report["workflow_outcomes"] = dict(fetch=fetch_outcome, publication_gate=gate_outcome)
    if fetch_outcome != "success" or not report.get("complete"):
        report["validation"]["status"] = "fail"
        report.setdefault("critical_failures", []).append(
            f"Fetch step outcome: {fetch_outcome}; publication is blocked.")
    if gate_outcome not in {"success", "failure"}:
        write_json(directory / "publication-decision.json", dict(
            status="validation-blocked", release_action="fail",
            reason="Freshness gate did not run because source validation/setup did not succeed.",
            validation_report="validation-report.json"))
    elif gate_outcome == "failure":
        decision_path = directory / "publication-decision.json"
        try:
            decision = json.loads(decision_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            decision = {}
        if decision.get("status") in {None, "validation-not-completed"}:
            write_json(decision_path, dict(status="publication-gate-error", release_action="fail",
                                          reason="Freshness gate failed before writing a decision; consult its log."))
    write_json(path, report)
    # Retained in the job log as well as the artifact; old artifact expiry must
    # not make the market periods and original errors impossible to investigate.
    print(json.dumps(report, indent=2))
    lines = ["## Source validation diagnostics", "", f"Policy: {POLICY}", "",
             "| Market | Result / reason | Observed / required period | Attempts | Source |",
             "|---|---|---|---|---|"]
    def cell(value):
        if isinstance(value, list):
            value = "; ".join(map(str, value))
        return str(value or "—").replace("|", "&#124;").replace("\n", " ").replace("\r", " ")
    for item in [report.get("worldwide_status", {})] + report.get("market_statuses", []):
        lines.append("| " + " | ".join(cell(v) for v in [
            item.get("code"), f"{item.get('status')}: {item.get('failure_type') or ''} {cell(item.get('errors'))}",
            f"{item.get('chart_period')} / {item.get('required_period')}",
            str(item.get("attempts", 0)), item.get("source_url")]) + " |")
    summary = "\n".join(lines) + "\n"
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(summary)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["init", "finalize"])
    parser.add_argument("--directory", type=Path, default=Path("staging/input"))
    parser.add_argument("--fetch-outcome", default="not-run")
    parser.add_argument("--gate-outcome", default="not-run")
    args = parser.parse_args()
    if args.action == "init":
        initialize(args.directory)
    else:
        report = finalize(args.directory, args.fetch_outcome, args.gate_outcome)
        sys.exit(0 if report.get("complete") and report["validation"]["status"] == "pass" else 1)
