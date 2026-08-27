#!/usr/bin/env python3

"""Select exactly one successful render candidate for tests and deployment."""

from __future__ import annotations

import argparse
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class RenderCandidate:
    renderer: str
    ready: bool
    artifact_name: str
    site_bytes: str = ""
    index_bytes: str = ""
    file_count: str = ""
    render_warning_count: str = ""


def fallback_eligible(*, primary_ready: bool, workflow_cancelled: bool) -> bool:
    """Mirror the fallback intent encoded by the workflow job condition."""
    return not workflow_cancelled and not primary_ready


def select_candidate(
    primary: RenderCandidate,
    fallback: RenderCandidate,
) -> RenderCandidate:
    ready = [candidate for candidate in (primary, fallback) if candidate.ready]
    if len(ready) != 1:
        raise ValueError(
            f"Expected exactly one successful render candidate; found {len(ready)}."
        )
    selected = ready[0]
    if not selected.artifact_name:
        raise ValueError(f"The {selected.renderer} candidate has no artifact name.")
    return selected


def parse_bool(raw: str) -> bool:
    return raw.strip().lower() == "true"


def write_github_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT", "").strip()
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")
    else:
        print(f"{name}={value}")


def append_summary(selected: RenderCandidate) -> None:
    summary = (
        "## Render candidate selection\n\n"
        f"- Successful candidate source: **{selected.renderer}**\n"
        f"- Artifact: `{selected.artifact_name}`\n"
    )
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY", "").strip()
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write(summary)
    else:
        print(summary, end="")


def candidate_from_args(args: argparse.Namespace, renderer: str) -> RenderCandidate:
    return RenderCandidate(
        renderer=renderer,
        ready=parse_bool(getattr(args, f"{renderer}_ready")),
        artifact_name=getattr(args, f"{renderer}_artifact"),
        site_bytes=getattr(args, f"{renderer}_site_bytes"),
        index_bytes=getattr(args, f"{renderer}_index_bytes"),
        file_count=getattr(args, f"{renderer}_file_count"),
        render_warning_count=getattr(args, f"{renderer}_render_warning_count"),
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    for renderer in ("primary", "fallback"):
        parser.add_argument(f"--{renderer}-ready", default="false")
        parser.add_argument(f"--{renderer}-artifact", default="")
        parser.add_argument(f"--{renderer}-site-bytes", default="")
        parser.add_argument(f"--{renderer}-index-bytes", default="")
        parser.add_argument(f"--{renderer}-file-count", default="")
        parser.add_argument(f"--{renderer}-render-warning-count", default="")
    args = parser.parse_args(argv)

    selected = select_candidate(
        candidate_from_args(args, "primary"),
        candidate_from_args(args, "fallback"),
    )
    for name, value in {
        "renderer": selected.renderer,
        "artifact_name": selected.artifact_name,
        "site_bytes": selected.site_bytes,
        "index_bytes": selected.index_bytes,
        "file_count": selected.file_count,
        "render_warning_count": selected.render_warning_count,
    }.items():
        write_github_output(name, value)
    append_summary(selected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
