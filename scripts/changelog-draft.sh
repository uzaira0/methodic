#!/usr/bin/env bash
# Draft the CHANGELOG section for a release from the curated commits staged for publish
# (scripts/publish.sh stage), across the root and every submodule.
#
#   scripts/changelog-draft.sh <release>        e.g. scripts/changelog-draft.sh 2026.09.10
#
# Prints Markdown to stdout: paste it under a new "## [<release>]" heading in CHANGELOG.md
# and edit it into prose a user can read. For each repository with a curate worktree, the
# commits after the public tip are read; the private history is never used, since it is
# scratch and carries no Conventional Commits guarantee.
set -euo pipefail
RELEASE="${1:?usage: scripts/changelog-draft.sh <release>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${CHRONICLE_PUBLISH_WORK:-$ROOT_DIR/../chronicle_work/publish/curate}"
command -v git-cliff >/dev/null || { echo "git-cliff is required (https://github.com/orhun/git-cliff/releases)" >&2; exit 1; }
cd "$ROOT_DIR"
echo "## [$RELEASE]"
echo
for label in $(git config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}' | xargs -n1 basename) root; do
  wt="$WORK/$label"; [[ -d "$wt" ]] || continue
  branch="$(cat "$WORK/.branch-$label" 2>/dev/null || true)"
  tip="$(git -C "$wt" rev-parse -q --verify "refs/remotes/public/${branch:-main}" 2>/dev/null || true)"
  range="${tip:+$tip..}HEAD"
  body="$(git -C "$wt" cliff --config "$ROOT_DIR/cliff.toml" --tag "$RELEASE" "$range" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
  [[ -n "$body" ]] || continue
  echo "<!-- $label -->"
  echo "$body"
  echo
done
