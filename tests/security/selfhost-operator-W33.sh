#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
POLICY="${ROOT_DIR}/SECURITY.md"
README="${ROOT_DIR}/selfhost/README.md"
fail() { echo "FAIL W33: $*" >&2; exit 1; }

grep -Fq 'For a source' "$POLICY" && grep -Fq 'checkout, include' "$POLICY" ||
  fail 'source-checkout commit identity is not scoped to source checkouts'
grep -Fq 'git rev-parse --short HEAD' "$POLICY" ||
  fail 'source-checkout reporting lost its commit identity'
grep -Fq 'release-manifest.json' "$POLICY" ||
  fail 'archive reporting still depends on unavailable Git metadata'
grep -Fq 'release_version' "$POLICY" || fail 'archive reporting omits its shipped release identity'
grep -Fq 'source_revision' "$POLICY" || fail 'archive reporting omits its source revision'
grep -Fq 'public_revision' "$POLICY" || fail 'archive reporting omits its public revision when present'
grep -Fq 'support commitments for shipped releases remain owned by' "$POLICY" ||
  fail 'reporting clarification does not state that release support commitments remain owner-maintained'
grep -Fq 'previous release as an upgrade' "$README" ||
  fail 'SECURITY reporting is not aligned with the bundle release guidance'
echo 'PASS W33: source and archive report identities are distinct; bundle support commitment remains maintainer-owned'
