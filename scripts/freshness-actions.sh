#!/usr/bin/env bash
# Audits action pin freshness. Compares every `uses: org/repo@<ref>` to the
# latest release tag of that action's repo. Reports stale pins.
set -euo pipefail

cd "$(dirname "$0")/.."
repo="${REPO:-uzaira0/methodic}"

# Extract distinct action pins
pins=$(grep -rhoE 'uses:\s+[a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+@[a-zA-Z0-9._-]+' \
    .github/workflows/ | sed -E 's/uses:\s+//' | sort -u)

stale=""
while IFS= read -r pin; do
    [ -z "$pin" ] && continue
    action="${pin%@*}"
    ref="${pin#*@}"

    # Skip our own _trivy-scan reusable
    case "$action" in
        ./.github/*) continue ;;
    esac

    # Resolve latest release of <action>'s repo
    latest=$(gh api "repos/$action/releases/latest" --jq '.tag_name' 2>/dev/null \
        || gh api "repos/$action/tags" --jq '.[0].name' 2>/dev/null \
        || echo "unknown")

    if [ "$latest" = "unknown" ]; then
        continue
    fi

    # Strip leading 'v' for comparison
    ref_strip="${ref#v}"
    latest_strip="${latest#v}"

    # If pinned by SHA (40 chars), check if it's the latest tag's commit SHA
    if [ ${#ref} -eq 40 ]; then
        latest_sha=$(gh api "repos/$action/git/refs/tags/$latest" \
            --jq '.object.sha' 2>/dev/null || echo "")
        if [ -n "$latest_sha" ] && [ "$latest_sha" != "$ref" ]; then
            stale+="- \`$action\`: pinned $ref (≠ latest $latest @ $latest_sha)"$'\n'
        fi
    else
        # Tag-pinned. Compare directly.
        if [ "$ref_strip" != "$latest_strip" ]; then
            # Major-version pins (v4) match the latest minor (v4.2.1) — accept
            major_ref=$(echo "$ref_strip" | cut -d. -f1)
            major_latest=$(echo "$latest_strip" | cut -d. -f1)
            if [ "$major_ref" != "$major_latest" ]; then
                stale+="- \`$action\`: pinned $ref (≠ latest $latest)"$'\n'
            fi
        fi
    fi
done <<< "$pins"

if [ -z "$stale" ]; then
    echo "No action pin drift. ✓"
    exit 0
fi

echo "Stale action pins:"
echo "$stale"

title="freshness:actions — $(date -u +%Y-%m-%d)"
body="# GitHub Actions Pin Freshness

Auto-detected by \`.github/workflows/freshness-actions.yml\`.

The following actions have newer releases than what we have pinned:

$stale

To update: edit the relevant workflow file in \`.github/workflows/\`. Re-run actionlint to verify."

existing=$(gh issue list --repo "$repo" --label "freshness:actions" --state open \
    --json number --jq '.[0].number // empty')
if [ -n "$existing" ]; then
    gh issue edit "$existing" --repo "$repo" --title "$title" --body "$body"
else
    gh label create "freshness:actions" --repo "$repo" --color "5319E7" \
        --description "GitHub Actions pin freshness" 2>/dev/null || true
    gh issue create --repo "$repo" --title "$title" --body "$body" \
        --label "freshness:actions"
fi
