#!/usr/bin/env python3

"""Stamp a tested site candidate immediately before Pages deployment."""

from __future__ import annotations

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path


DEPLOYED_AT_PATTERN = re.compile(
    r'(<span id="site-deployed-at">)(.*?)(</span>)',
    flags=re.DOTALL,
)


def finalize_site(site_dir: Path, deployed_at: str, run_url: str) -> None:
    manifest_path = site_dir / "deployment-manifest.json"
    index_path = site_dir / "index.html"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["deployed_at"] = deployed_at
    manifest["run_url"] = run_url
    manifest_path.write_text(
        json.dumps(manifest, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )

    html = index_path.read_text(encoding="utf-8")
    html, count = DEPLOYED_AT_PATTERN.subn(
        rf"\g<1>{deployed_at}\g<3>",
        html,
        count=1,
    )
    if count != 1:
        raise ValueError("Could not locate the site deployment timestamp marker")
    index_path.write_text(html, encoding="utf-8")

    verified = json.loads(manifest_path.read_text(encoding="utf-8"))
    if verified.get("deployed_at") != deployed_at or verified.get("run_url") != run_url:
        raise ValueError("Deployment metadata verification failed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("site_dir")
    args = parser.parse_args()
    deployed_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    server_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    repository = os.environ.get("GITHUB_REPOSITORY", "local")
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    run_url = f"{server_url}/{repository}/actions/runs/{run_id}" if run_id != "local" else "local"
    finalize_site(Path(args.site_dir), deployed_at, run_url)
    print(f"Finalized deployment metadata at {deployed_at}.")


if __name__ == "__main__":
    main()
