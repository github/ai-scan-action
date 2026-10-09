#!/usr/bin/env bash
#
# Unpacks the AI Scan distribution tarball and verifies that the Bun
# runtime on PATH is the exact version the bundle was built for.
# `action.yml` provisions that version (read from the tarball by its
# "resolve" step) before calling this script, so a mismatch means the
# runner's Bun drifted from what was requested.
#
# Prints the package directory — the only thing written to stdout — on
# success. This is the single source of truth for where the bundle
# landed: callers capture it rather than reconstructing the path.
# Diagnostics go to stderr.
#
# Usage:
#   unpack.sh <work-dir> <tarball>
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <work-dir> <tarball>" >&2
  exit 2
fi

work_dir="$1"
tarball="$2"
package_dir="${work_dir}/argus-core-package"

mkdir -p "${package_dir}"
tar -xJf "${tarball}" -C "${package_dir}"
argus_bundle="${package_dir}/argus.js"
bun_version_stamp="${package_dir}/ai-scan-bun-version"
if [ ! -f "${argus_bundle}" ] || [ ! -f "${bun_version_stamp}" ]; then
  echo "unpack.sh: ${tarball} is not an AI Scan bundle archive (expected argus.js and ai-scan-bun-version)." >&2
  exit 1
fi

expected_bun_version="$(cat "${bun_version_stamp}")"
actual_bun_version="$(env -C "${package_dir}" bun --version)"
if [ "${expected_bun_version}" != "${actual_bun_version}" ]; then
  echo "unpack.sh: AI Scan was built for Bun ${expected_bun_version} but this runner has Bun ${actual_bun_version}." >&2
  exit 1
fi

echo "${package_dir}"
