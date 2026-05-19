#!/usr/bin/env bash
# Triggers the Build Android APK workflow and monitors it until completion.
# Usage: ./build-apk.sh [server_url] [build_type] [android_ref]
#
# Defaults:
#   server_url:  http://cnrc-deni-p001.cnrc.bcm.edu
#   build_type:  debug
#   android_ref: develop

set -euo pipefail

export PATH="/tmp/gh_2.65.0_linux_amd64/bin:$PATH"
TOKEN=$(head -1 ~/.git-credentials | sed 's|https://x-access-token:\([^@]*\)@.*|\1|')
export GH_TOKEN="$TOKEN"

REPO="uzaira0/chronicle"
WORKFLOW="build-android-apk.yml"
SERVER_URL="${1:-http://cnrc-deni-p001.cnrc.bcm.edu}"
BUILD_TYPE="${2:-debug}"
ANDROID_REF="${3:-develop}"

echo "=== Triggering APK build ==="
echo "  Server URL:  $SERVER_URL"
echo "  Build type:  $BUILD_TYPE"
echo "  Android ref: $ANDROID_REF"
echo ""

# Trigger the workflow
gh workflow run "$WORKFLOW" \
  --repo "$REPO" \
  --ref develop \
  -f server_url="$SERVER_URL" \
  -f android_ref="$ANDROID_REF" \
  -f build_type="$BUILD_TYPE"

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
      echo "Downloading APK artifact..."
      mkdir -p /tmp/apk-output
      gh run download "$RUN_ID" --repo "$REPO" --dir /tmp/apk-output 2>/dev/null && \
        echo "APK downloaded to /tmp/apk-output/" && \
        find /tmp/apk-output -name '*.apk' -exec ls -lh {} \; || \
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
    exit 0
  fi

  # Show progress
  STEP=$(gh run view "$RUN_ID" --repo "$REPO" --json jobs --jq '
    [.jobs[0].steps[] | select(.status == "in_progress" or .status == "queued")] |
    if length > 0 then .[0].name else "waiting" end
  ' 2>/dev/null || echo "...")
  printf "\r  Status: %-12s Step: %-50s" "$STATUS" "$STEP"

  sleep 10
done
