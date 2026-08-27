#!/usr/bin/env bash

set -Eeuo pipefail

attempt="${1:?render attempt label is required}"
site_dir="${2:?site output directory is required}"
started_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

finish() {
  status=$?
  trap - EXIT
  completed_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Render attempt completion UTC: ${completed_at}"
  echo "Render attempt exit code: ${status}"
  exit "${status}"
}
trap finish EXIT

echo "Render attempt: ${attempt}"
echo "Render attempt start UTC: ${started_at}"
echo "Runner OS: ${RUNNER_OS:-unknown}"
echo "Runner architecture: ${RUNNER_ARCH:-unknown}"
echo "Runner image OS: ${ImageOS:-not provided}"
echo "Runner image version: ${ImageVersion:-not provided}"
echo "Kernel: $(uname -srmo)"
echo "Quarto version: $(quarto --version)"
pandoc_version="$(quarto pandoc --version)"
echo "Pandoc version: ${pandoc_version%%$'\n'*}"
free -h | sed -n '1,2p'
df -h "${GITHUB_WORKSPACE:-.}" | tail -n 1

rm -rf "${site_dir}"
mkdir -p "${site_dir}"
quarto render world-music-watch.qmd --output-dir "${site_dir}"

echo "Successful candidate source: ${attempt}"
