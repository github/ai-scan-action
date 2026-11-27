#!/usr/bin/env bash
#
# Unpacks the AI Scan distribution tarball and checks its entry point.
#
# Prints the package directory — the only thing written to stdout — on
# success. This is the single source of truth for where the bundle
# landed: callers capture it rather than reconstructing the path.
# Diagnostics go to stderr.
#
# Usage:
#   unpack.sh <work-dir> <tarball>
#
# Environment:
#   ARGUS_RUNTIME      Runtime that `resolve-tools.mjs` selected for the
#                      archive: `node` (default) for `argus.mjs` bundles,
#                      or `bun` for older `argus.js` bundles.
#   ARGUS_BUN_VERSION  For `bun`: the Bun version in the archive's
#                      `ai-scan-bun-version` stamp. The Bun on PATH must
#                      be this exact version.
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <work-dir> <tarball>" >&2
  exit 2
fi

work_dir="$1"
tarball="$2"
runtime="${ARGUS_RUNTIME:-node}"
package_dir="${work_dir}/argus-core-package"

case "${runtime}" in
  node) entry_point="argus.mjs" ;;
  # TODO(bun-compat): Remove the Bun branch after production bundles use Node.
  bun) entry_point="argus.js" ;;
  *)
    echo "unpack.sh: unsupported AI Scan runtime: ${runtime}" >&2
    exit 2
    ;;
esac

# Remove an earlier extraction so its files cannot satisfy the checks below.
rm -rf "${package_dir}"
mkdir -p "${package_dir}"
tar -xJf "${tarball}" -C "${package_dir}"
if [ ! -f "${package_dir}/${entry_point}" ]; then
  echo "unpack.sh: ${tarball} is not an AI Scan ${runtime} bundle archive (expected ${entry_point})." >&2
  exit 1
fi

if [ "${runtime}" = "bun" ]; then
  stamp_file="${package_dir}/ai-scan-bun-version"
  if [ ! -f "${stamp_file}" ]; then
    echo "unpack.sh: ${tarball} does not contain an ai-scan-bun-version stamp." >&2
    exit 1
  fi
  expected_bun_version="$(tr -d '[:space:]' <"${stamp_file}")"
  if [ -n "${ARGUS_BUN_VERSION:-}" ] && [ "${ARGUS_BUN_VERSION}" != "${expected_bun_version}" ]; then
    echo "unpack.sh: resolved Bun ${ARGUS_BUN_VERSION} does not match the archive stamp ${expected_bun_version}." >&2
    exit 1
  fi
  actual_bun_version="$(env -C "${package_dir}" bun --version)"
  if [ "${actual_bun_version}" != "${expected_bun_version}" ]; then
    echo "unpack.sh: AI Scan requires Bun ${expected_bun_version}, but Bun ${actual_bun_version} is installed." >&2
    exit 1
  fi
fi

echo "${package_dir}"
