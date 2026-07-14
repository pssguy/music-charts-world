#!/usr/bin/env python3

import json
import os
import urllib.request


url = "https://musiccharts.world/deployment-manifest.json"
try:
    request = urllib.request.Request(url, headers={"User-Agent": "MusicCharts.world workflow"})
    with urllib.request.urlopen(request, timeout=10) as response:
        manifest = json.load(response)
    previous_bytes = int(manifest["site_bytes"])
    if previous_bytes <= 0:
        raise ValueError("site_bytes is not positive")
except Exception as error:
    print(f"Previous deployment size comparison unavailable: {error}")
else:
    env_path = os.environ.get("GITHUB_ENV", "").strip()
    if env_path:
        with open(env_path, "a", encoding="utf-8") as handle:
            handle.write(f"MUSICCHARTS_PREVIOUS_SITE_BYTES={previous_bytes}\n")
    print(f"Previous deployment size: {previous_bytes} bytes")
