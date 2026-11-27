#!/usr/bin/env bash
#
# AI Scan core runner. Resolves the Copilot CLI and invokes AI Scan
# core from an already-unpacked package directory (see `unpack.sh`,
# which does the tarball extraction). This
# runner does not inspect the CLI's inputs — the CLI reads everything
# it needs from the environment.
#
# Node bundles (`argus.mjs`) run on Node.js 22, provisioned by `action.yml`.
# Bundles built before the switch to Node.js (`argus.js`) run on the Bun
# version that `action.yml` sets up from the archive's stamp. The Copilot
# CLI always runs on Node.js.
#
# The bundle reports the `@github/copilot` version required by AI Scan.
# This runner installs that exact version in an isolated directory.
#
# Usage:
#   run.sh <work-dir> <package-dir>
#
# Environment:
#   ARGUS_RUNTIME        Runtime for the bundle: `node` (default) runs
#                        `argus.mjs`, `bun` runs `argus.js`.
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
#                        built (`github.ref`); ignored for PR scans.
#   GITHUB_EVENT_NAME,  PR scans compare the event's base and PR-head
#   GITHUB_EVENT_PATH   SHAs through GitHub's REST API.
# Optional run provenance, forwarded verbatim and reported in telemetry:
#   ARGUS_ACTION_VERSION Ref the action was invoked at (`github.action_ref`).
#   ARGUS_IMPLEMENTATION_VERSION
#                        Release tag of the AI Scan archive being run.
#   ARGUS_ACTION_STARTED_AT
#                        RFC 3339 timestamp of when the action started.
#   ARGUS_TELEMETRY_OUTBOX
#                        Directory in which the run keeps its telemetry
#                        outbox, so `finalize-telemetry` can send the
#                        final report if this run dies first. The action
#                        puts it in the runner's temp directory.
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <work-dir> <package-dir>" >&2
  exit 2
fi
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

work_dir="$1"
package_dir="$2"
copilot_dir="${work_dir}/argus-copilot"
github_copilot_token="${ARGUS_COPILOT_TOKEN:-${GITHUB_TOKEN}}"
github_copilot_integration_id="${ARGUS_COPILOT_INTEGRATION_ID:-}"
argus_runtime="${ARGUS_RUNTIME:-node}"
case "${argus_runtime}" in
  node) argus_bundle="${package_dir}/argus.mjs" ;;
  # TODO(bun-compat): Remove the Bun branch after production bundles use Node.
  bun) argus_bundle="${package_dir}/argus.js" ;;
  *)
    echo "run.sh: unsupported AI Scan runtime: ${argus_runtime}" >&2
    exit 2
    ;;
esac

copilot_version="$(env -C "${package_dir}" "${argus_runtime}" "${argus_bundle}" copilot-cli-version)"
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

env -C "${package_dir}" "${argus_env[@]}" "${argus_runtime}" "${argus_bundle}" actions-security-generic
