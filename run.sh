#!/usr/bin/env bash
#
# AI Scan core runner. Unpacks the distribution tarball, resolves the
# Copilot CLI, and invokes AI Scan core. Whether the tarball came from a
# release download or was built from source is opaque here, and this runner
# does not inspect the CLI's inputs — the CLI reads everything it needs from
# the environment.
#
# The tarball holds a JavaScript bundle (`argus.js`), not an executable, so a
# Bun runtime must already be on PATH. `action.yml` reads the version recorded
# in the tarball and provisions that exact runtime before calling this script.
#
# The bundle reports the `@github/copilot` version required by AI Scan.
# This runner installs that exact version in an isolated directory.
#
# Usage:
#   run.sh <work-dir> <tarball>
#
# Environment:
#   GITHUB_TOKEN         Forwarded to AI Scan for the Octokit client
#                        and used as the default Copilot credential.
#   ARGUS_COPILOT_TOKEN  Optional Copilot-only credential.
#   ARGUS_COPILOT_INTEGRATION_ID
#                        Optional integration ID for Copilot requests.
# The remaining values are required by the CLI and forwarded verbatim:
#   GITHUB_REPOSITORY,   Populated by the GitHub Actions runner; the
#   GITHUB_REF,          CLI reads them directly to plumb Code Scanning
#   GITHUB_SHA,          wiring and the checkout root through.
#   GITHUB_WORKSPACE
#   ARGUS_SOURCE_ROOT    Subdirectory of the checkout to scan, relative
#                        to GITHUB_WORKSPACE. The action defaults it to
#                        `.` (scan the whole checkout).
#   ARGUS_BASELINE_REF   Baseline git ref reverify compares against.
#                        The action defaults it to the ref being
#                        built (`github.ref`).
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <work-dir> <tarball>" >&2
  exit 2
fi
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

work_dir="$1"
tarball="$2"
package_dir="${work_dir}/argus-core-package"
copilot_dir="${work_dir}/argus-copilot"
github_copilot_token="${ARGUS_COPILOT_TOKEN:-${GITHUB_TOKEN}}"
github_copilot_integration_id="${ARGUS_COPILOT_INTEGRATION_ID:-}"

mkdir -p "${package_dir}"
tar -xJf "${tarball}" -C "${package_dir}"
argus_bundle="${package_dir}/argus.js"
bun_version_stamp="${package_dir}/ai-scan-bun-version"
if [ ! -f "${argus_bundle}" ] || [ ! -f "${bun_version_stamp}" ]; then
  echo "run.sh: ${tarball} is not an AI Scan bundle archive (expected argus.js and ai-scan-bun-version)." >&2
  echo "run.sh: archives released before AI Scan moved from a compiled executable to a JavaScript bundle are not usable by this action." >&2
  exit 1
fi

expected_bun_version="$(cat "${bun_version_stamp}")"
actual_bun_version="$(env -C "${package_dir}" bun --version)"
if [ "${expected_bun_version}" != "${actual_bun_version}" ]; then
  echo "run.sh: AI Scan was built for Bun ${expected_bun_version} but this runner has Bun ${actual_bun_version}." >&2
  exit 1
fi

copilot_version="$(env -C "${package_dir}" bun "${argus_bundle}" copilot-cli-version)"
if [[ ! "${copilot_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
  echo "run.sh: invalid required Copilot CLI version reported by Argus: ${copilot_version}" >&2
  exit 1
fi
echo "run.sh: installing required @github/copilot@${copilot_version}"
npm install --prefix "${copilot_dir}" --no-save "@github/copilot@${copilot_version}"
COPILOT_CLI_PATH="${copilot_dir}/node_modules/.bin/copilot"
test -x "${COPILOT_CLI_PATH}"
export COPILOT_CLI_PATH

argus_env=(COPILOT_GITHUB_TOKEN="${github_copilot_token}")
if [ -n "${github_copilot_integration_id}" ]; then
  argus_env+=(GITHUB_COPILOT_INTEGRATION_ID="${github_copilot_integration_id}")
fi

env -C "${package_dir}" "${argus_env[@]}" bun "${argus_bundle}" actions-security-generic
