#!/usr/bin/env bash
# Triggers the pinned-submodule Android distribution workflow and monitors it.
# Usage: ./build-apk.sh [play|amazon|research] [debug|release] [research_server_host]
#
# Defaults:
#   distribution: play
#   build_type:   release
#
# The workflow always builds the Android gitlink committed by CHRONICLE_WORKFLOW_REF. Public
# Play/Amazon builds accept no deployment host or shared HMAC input. A bare TLS hostname is
# accepted only for the explicitly controlled research flavor.

set -euo pipefail

REPO="uzaira0/chronicle"
WORKFLOW="build-android-apk.yml"
DISTRIBUTION="${1:-play}"
BUILD_TYPE="${2:-release}"
SERVER_HOST="${3:-${CHRONICLE_RESEARCH_SERVER_HOST:-}}"
WORKFLOW_REF="${CHRONICLE_WORKFLOW_REF:-develop}"

command -v gh >/dev/null 2>&1 || {
  echo "ERROR: GitHub CLI (gh) is required" >&2
  exit 1
}
gh auth status --hostname github.com >/dev/null 2>&1 || {
  echo "ERROR: authenticate GitHub CLI first with 'gh auth login' or a protected GH_TOKEN" >&2
  exit 1
}
case "$DISTRIBUTION" in play|amazon|research) ;; *) echo "ERROR: unsupported distribution" >&2; exit 2 ;; esac
case "$BUILD_TYPE" in debug|release) ;; *) echo "ERROR: unsupported build type" >&2; exit 2 ;; esac
if [[ "$DISTRIBUTION" == research ]]; then
  [[ "$SERVER_HOST" =~ ^[a-z0-9.-]+$ ]] || {
    echo "ERROR: controlled research builds require a bare TLS server hostname" >&2
    exit 2
  }
elif [[ -n "$SERVER_HOST" ]]; then
  echo "ERROR: a deployment host is accepted only for the controlled research flavor" >&2
  exit 2
fi

echo "=== Triggering APK build ==="
echo "  Distribution: $DISTRIBUTION"
echo "  Build type:   $BUILD_TYPE"
echo "  Workflow ref: $WORKFLOW_REF"
echo ""

# Trigger the workflow
workflow_args=(
  workflow run "$WORKFLOW"
  --repo "$REPO"
  --ref "$WORKFLOW_REF"
  -f "distribution=$DISTRIBUTION"
  -f "build_type=$BUILD_TYPE"
)
if [[ "$DISTRIBUTION" == research ]]; then
  workflow_args+=(-f "server_host=$SERVER_HOST")
fi
gh "${workflow_args[@]}"

echo "Workflow dispatched. Waiting for it to appear..."
sleep 5

# Find the most recent run
RUN_ID=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId')

if [ -z "$RUN_ID" ]; then
  echo "ERROR: Could not find workflow run"
  exit 1
fi

echo "Monitoring run #$RUN_ID..."
echo "  URL: https://github.com/$REPO/actions/runs/$RUN_ID"
echo ""

# Poll until completion
while true; do
  STATUS=$(gh run view "$RUN_ID" --repo "$REPO" --json status,conclusion --jq '.status')

  if [ "$STATUS" = "completed" ]; then
    CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq '.conclusion')
    echo ""
    if [ "$CONCLUSION" = "success" ]; then
      echo "=== BUILD SUCCEEDED ==="
      echo ""
      echo "Downloading Android artifact..."
      artifact_parent="${CHRONICLE_ANDROID_ARTIFACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/build/github-android-artifacts}"
      [[ "$artifact_parent" == /* ]] || { echo "ERROR: artifact root must be absolute" >&2; exit 1; }
      case "$artifact_parent" in /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders|/var/folders/*) echo "ERROR: artifact root must not use a system temporary directory" >&2; exit 1 ;; esac
      umask 077
      mkdir -p "$artifact_parent"
      chmod 0700 "$artifact_parent"
      artifact_dir="$artifact_parent/run-$RUN_ID"
      [[ ! -e "$artifact_dir" ]] || { echo "ERROR: artifact directory already exists: $artifact_dir" >&2; exit 1; }
      mkdir -m 0700 "$artifact_dir"
      gh run download "$RUN_ID" --repo "$REPO" --dir "$artifact_dir" 2>/dev/null && \
        echo "Artifact downloaded to $artifact_dir/" && \
        find "$artifact_dir" -type f \( -name '*.apk' -o -name '*.aab' \) -exec ls -lh {} \; || \
        echo "  (Download available at: https://github.com/$REPO/actions/runs/$RUN_ID)"
    else
      echo "=== BUILD FAILED (conclusion: $CONCLUSION) ==="
      echo ""
      echo "Failed step logs:"
      echo "---"
      gh run view "$RUN_ID" --repo "$REPO" --log-failed 2>/dev/null | tail -80
      echo "---"
      echo ""
      echo "Full logs: https://github.com/$REPO/actions/runs/$RUN_ID"
    fi
    [[ "$CONCLUSION" == success ]] && exit 0
    exit 1
  fi

  # Show progress
  STEP=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs --jq '
    [.jobs[0].steps[] | select(.status == "in_progress" or .status == "queued")] |
    if length > 0 then .[0].name else "waiting" end
  ' 2>/dev/null || echo "...")
  printf "\r  Status: %-12s Step: %-50s" "$STATUS" "$STEP"

  sleep 10
done
