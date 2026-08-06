#!/usr/bin/env python3

import os
import re
from pathlib import Path

required = [
    Path("R/fetch_charts.R"),
    Path("world-music-watch.qmd"),
    Path("_quarto.yml"),
    Path("CNAME"),
    Path("robots.txt"),
    Path("DESCRIPTION"),
    Path("scripts/publication_gate.py"),
    Path("scripts/finalize_deployment.py"),
]
missing = [str(path) for path in required if not path.is_file()]
if missing:
    raise SystemExit("Missing release inputs: " + ", ".join(missing))

if Path("CNAME").read_text(encoding="utf-8").strip() != "musiccharts.world":
    raise SystemExit("CNAME must contain exactly musiccharts.world")

source = Path("R/fetch_charts.R").read_text(encoding="utf-8")
match = re.search(
    r"WORLD_MUSIC_WATCH_COUNTRIES\s*<-\s*c\((.*?)\)\s*$",
    source,
    flags=re.DOTALL,
)
if not match:
    raise SystemExit("Could not locate the configured market vector")
markets = re.findall(r'"([a-z]{2})"', match.group(1))
if len(markets) != 55 or len(set(markets)) != 55:
    raise SystemExit(f"Expected 55 unique configured markets; found {len(markets)}")

if os.environ.get("MUSICCHARTS_TEST_MARKETS", "").strip():
    raise SystemExit("MUSICCHARTS_TEST_MARKETS must not be set in a release run")

workflow = Path(".github/workflows/render-deploy.yml").read_text(encoding="utf-8")
expected_crons = {'cron: "0 18 * * 5"', 'cron: "0 18 * * 6"'}
actual_crons = set(re.findall(r'cron:\s*"[^"]+"', workflow))
if actual_crons != expected_crons:
    raise SystemExit(f"Unexpected publication schedule: {sorted(actual_crons)}")
if not re.search(r"(?m)^\s*push:\s*$", workflow) or not re.search(
    r"(?m)^\s*workflow_dispatch:\s*$", workflow
):
    raise SystemExit("The release workflow must preserve push and workflow_dispatch triggers")

print("Release configuration passed: schedule, triggers, main site, custom domain, and 55 unique markets.")
