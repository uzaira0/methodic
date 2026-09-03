#!/usr/bin/env bash
# Toolchain drift checker — enforces toolchain-manifest.yaml against the repo.
#
# Covers root AND submodules: gradle wrappers, workflow JDK pins, Bun pins,
# Kotlin/Mockito/Flyway version sync, and the single Postgres test/prod image
# constant. Run standalone, from scripts/local-ci.sh, or from ci.yml. Exits
# non-zero on any drift; every check names the file and the expected pin.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/toolchain-manifest.yaml"
FAILURES=0

fail() { printf '[fail] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf '[ok] %s\n' "$*"; }

manifest_value() { # dotted.path
  yq -r ".$1" "$MANIFEST"
}

JDK="$(manifest_value jdk.build_runtime)"
ANDROID_JDK="$(manifest_value jdk.android_launcher)"
GRADLE="$(manifest_value gradle.wrapper)"
ANDROID_GRADLE="$(manifest_value gradle.android_wrapper)"
KOTLIN="$(manifest_value kotlin)"
BUN="$(manifest_value bun)"
PG_IMAGE="$(manifest_value postgres.image)"
PG_DIGEST="$(manifest_value postgres.index_digest)"
KC_PG_IMAGE="$(manifest_value keycloak_postgres.image)"
KC_PG_DIGEST="$(manifest_value keycloak_postgres.index_digest)"
FLYWAY="$(manifest_value flyway.version)"
SELFHOST_BACKUP_IMAGE="$(manifest_value selfhost_images.backup)"
SELFHOST_CADVISOR_IMAGE="$(manifest_value selfhost_images.cadvisor)"
SELFHOST_VM_IMAGE="$(manifest_value selfhost_images.victoria_metrics)"
SELFHOST_VL_IMAGE="$(manifest_value selfhost_images.victoria_logs)"
SELFHOST_FLUENT_BIT_IMAGE="$(manifest_value selfhost_images.fluent_bit)"
SELFHOST_GRAFANA_IMAGE="$(manifest_value selfhost_images.grafana)"
SELFHOST_KEYCLOAK_IMAGE="$(manifest_value selfhost_images.keycloak)"

# ── 1. Gradle wrappers ────────────────────────────────────────────────────────
for m in . chronicle-server chronicle-api rhizome rhizome-client; do
  f="$ROOT_DIR/$m/gradle/wrapper/gradle-wrapper.properties"
  if grep -q "gradle-${GRADLE}-bin.zip" "$f" 2>/dev/null; then
    ok "wrapper $m -> $GRADLE"
  else
    fail "wrapper $m is not Gradle $GRADLE ($f)"
  fi
done
f="$ROOT_DIR/chronicle/gradle/wrapper/gradle-wrapper.properties"
if grep -q "gradle-${ANDROID_GRADLE}-bin.zip" "$f" 2>/dev/null; then
  ok "wrapper chronicle (Android) -> $ANDROID_GRADLE"
else
  fail "Android wrapper is not Gradle $ANDROID_GRADLE ($f)"
fi

# ── 2. Workflow JDK pins (root + submodules) ─────────────────────────────────
# Everything must be on $JDK except the Android APK build jobs, which stay on
# the Android launcher JDK.
ANDROID_JDK_ALLOWED=(
  ".github/workflows/build-android-apk.yml"
  ".github/workflows/maestro-android-test.yml"
)
while IFS=: read -r file _ line; do
  rel="${file#"$ROOT_DIR"/}"
  ver="$(sed -E "s/.*java-version: *['\"]?([0-9]+).*/\1/" <<<"$line")"
  if [[ "$ver" == "$JDK" ]]; then
    continue
  fi
  allowed=0
  if [[ "$ver" == "$ANDROID_JDK" ]]; then
    for a in "${ANDROID_JDK_ALLOWED[@]}"; do [[ "$rel" == "$a" ]] && allowed=1; done
    # Android submodule workflows may use the Android JDK too.
    [[ "$rel" == chronicle/.github/* ]] && allowed=1
  fi
  if [[ "$allowed" -ne 1 ]]; then
    fail "JDK pin drift: $rel pins java-version $ver (expected $JDK)"
  fi
done < <(grep -rn 'java-version:' \
  "$ROOT_DIR/.github/workflows" \
  "$ROOT_DIR"/chronicle-server/.github/workflows \
  "$ROOT_DIR"/chronicle-api/.github/workflows \
  "$ROOT_DIR"/chronicle-models/.github/workflows \
  "$ROOT_DIR"/rhizome/.github/workflows \
  "$ROOT_DIR"/rhizome-client/.github/workflows \
  "$ROOT_DIR"/chronicle/.github/workflows 2>/dev/null)
# The per-file allowance above is too coarse for maestro-android-test.yml: its APK
# builder and Maestro driver use the Android JDK; the backend stays on $JDK.
MAESTRO_ANDROID_PINS="$(grep -c "java-version: [\"']${ANDROID_JDK}[\"']" "$ROOT_DIR/.github/workflows/maestro-android-test.yml" 2>/dev/null || true)"
[[ "${MAESTRO_ANDROID_PINS:-0}" -eq 2 ]] \
  || fail "maestro-android-test.yml has ${MAESTRO_ANDROID_PINS} java-version ${ANDROID_JDK} pins (build-apk and the Maestro driver must use the Android JDK)"
ok "workflow JDK pins checked (expected $JDK; Android jobs $ANDROID_JDK)"

# ── 3. Bun pins (root + web submodule; Node must not reappear) ───────────────
# Remember the failure count so the closing summary is only printed when this section
# actually passed -- otherwise a drift prints "[fail] ..." immediately followed by
# "[ok] bun pins checked", and anyone scanning for [ok] reads the green line.
BUN_FAILURES_BEFORE=$FAILURES
while IFS=: read -r file _ line; do
  rel="${file#"$ROOT_DIR"/}"
  ver="$(sed -E "s/.*bun-version: *['\"]?([0-9.]+).*/\1/" <<<"$line")"
  [[ "$ver" == "$BUN" ]] || fail "Bun pin drift: $rel pins $ver (expected $BUN)"
done < <(grep -rn 'bun-version:' "$ROOT_DIR/.github" "$ROOT_DIR/chronicle-web/.github" 2>/dev/null)
# The two guard scripts hardcode their own Bun literals (they cannot depend on yq);
# cross-check them against the manifest so the gates cannot contradict each other.
grep -Eq "^[[:space:]]*BUN_VERSION=[\"']?${BUN}" "$ROOT_DIR/tests/security/supply-chain-guardrails.sh" \
  || fail "supply-chain-guardrails.sh BUN_VERSION != $BUN"
grep -q "bun-version: ${BUN}" "$ROOT_DIR/scripts/check-bun-workflows.sh" \
  || fail "check-bun-workflows.sh expected bun-version literal != $BUN"

# chronicle-web/package.json pins `bun` and `bun-types` as exact versions, and until now
# nothing compared them to the manifest -- every check above only reads `bun-version:` keys
# in workflows. Dependabot bumped bun-types to 1.3.14 (chronicle-web#153) and it merged
# unnoticed, which broke `bun install --frozen-lockfile`: bun.lock still held the manifest
# version, so package.json and the lockfile disagreed and the install refused to run.
#
# The manifest is the source of truth for version pins, so the correct response to that
# Dependabot PR is to close it, not to merge it and move the lockfile.
PKG="$ROOT_DIR/chronicle-web/package.json"
if [[ -f "$PKG" ]]; then
  for dep in bun bun-types; do
    ver="$(jq -r --arg d "$dep" '(.dependencies[$d] // .devDependencies[$d]) // ""' "$PKG")"
    if [[ -z "$ver" ]]; then
      fail "chronicle-web/package.json does not pin '$dep' (expected $BUN)"
    elif [[ "$ver" != "$BUN" ]]; then
      fail "Bun pin drift: chronicle-web/package.json pins $dep $ver (expected $BUN). The manifest is the source of truth — close the Dependabot PR rather than merging it."
    fi
  done
  # The lockfile is what `--frozen-lockfile` actually enforces, so a package.json that
  # matches the manifest while bun.lock does not still fails every install and CI job.
  LOCK="$ROOT_DIR/chronicle-web/bun.lock"
  if [[ -f "$LOCK" ]]; then
    grep -q "\"bun-types@${BUN}\"" "$LOCK" \
      || fail "chronicle-web/bun.lock does not resolve bun-types to $BUN — regenerate the web lockfile with the pinned Bun runtime"
  fi
fi
[[ "$FAILURES" -eq "$BUN_FAILURES_BEFORE" ]] \
  && ok "bun pins checked (expected $BUN, incl. chronicle-web package.json + bun.lock)"

# ── 4. Version sync: Kotlin, Flyway, Mockito floor ───────────────────────────
# Anchored to line starts so a commented-out old pin cannot satisfy the check.
grep -Eq "^[[:space:]]*ext\.kotlin_version='${KOTLIN}'" "$ROOT_DIR/gradles/chronicle.gradle" \
  && ok "kotlin $KOTLIN in gradles/chronicle.gradle" \
  || fail "gradles/chronicle.gradle kotlin_version != $KOTLIN"

# Kotlin pins are necessarily duplicated in every pluginManagement block (settings
# files cannot read external config) and in the root stdlib forces — sweep them all.
for f in settings.gradle.kts build.gradle.kts \
  chronicle-server/settings.gradle chronicle-api/settings.gradle \
  chronicle-models/settings.gradle rhizome/settings.gradle rhizome-client/settings.gradle; do
  STALE="$(grep -En "^[^/]*(kotlin[^:]*version|kotlin-stdlib-jdk[78]:)" "$ROOT_DIR/$f" 2>/dev/null | grep -v "${KOTLIN}" || true)"
  if [[ -n "$STALE" ]]; then
    fail "kotlin pin drift in $f (expected $KOTLIN): $(head -1 <<<"$STALE")"
  else
    ok "kotlin pins in $f -> $KOTLIN"
  fi
done

grep -q "ext.flyway_version='${FLYWAY}'" "$ROOT_DIR/gradles/chronicle.gradle" \
  && ok "flyway $FLYWAY in gradles/chronicle.gradle" \
  || fail "gradles/chronicle.gradle flyway_version != $FLYWAY"

grep -q "flyway/flyway:${FLYWAY}" "$ROOT_DIR/scripts/flyway-migrate.sh" \
  && ok "flyway $FLYWAY in scripts/flyway-migrate.sh" \
  || fail "scripts/flyway-migrate.sh image != flyway/flyway:$FLYWAY"

# ── 5. Postgres image constant ────────────────────────────────────────────────
grep -q "PROD_POSTGRES_IMAGE = \"${PG_IMAGE}\"" \
  "$ROOT_DIR/chronicle-server/src/test/kotlin/com/openlattice/chronicle/contract/ChronicleContractTestSchema.kt" \
  && ok "testcontainer image constant -> $PG_IMAGE" \
  || fail "ChronicleContractTestSchema.PROD_POSTGRES_IMAGE != $PG_IMAGE"

# No test source may hard-code its own copy of the image string (they must reference
# the constant): a duplicate literal is invisible to a manifest bump.
DUP_PINS="$(grep -rEn '= *"percona/percona-distribution-postgresql' "$ROOT_DIR/chronicle-server/src" \
  | grep -v 'ChronicleContractTestSchema.kt' || true)"
[[ -z "$DUP_PINS" ]] \
  && ok "no duplicate image literals in chronicle-server test sources" \
  || fail "duplicate postgres image literal outside ChronicleContractTestSchema: $(head -1 <<<"$DUP_PINS")"

for f in docker/docker-compose.traefik.yml docker/docker-compose.prod.yml \
  docker/docker-compose.yml docker/docker-compose.dev.yml \
  .github/workflows/maestro-android-test.yml .github/workflows/backup-restore-test.yml; do
  grep -Eq "^[[:space:]]*image: ${PG_IMAGE}" "$ROOT_DIR/$f" \
    && ok "$f -> $PG_IMAGE" \
    || fail "$f postgres image != $PG_IMAGE"
done

# k8s manifests carry the same tag digest-pinned (tag@sha256:...) — a manifest bump
# must not leave them behind.
K8S_STALE="$(grep -rEn '^[[:space:]]*(image|value):.*percona/percona-distribution-postgresql' "$ROOT_DIR/k8s" 2>/dev/null | grep -v "${PG_IMAGE}@sha256:" | grep -v "${PG_IMAGE}\$" || true)"
[[ -z "$K8S_STALE" ]] \
  && ok "k8s manifests -> $PG_IMAGE (digest-pinned)" \
  || fail "k8s postgres image drift: $(head -1 <<<"$K8S_STALE")"

# The digest the manifest records must be the one every digest-pinned artifact uses.
# Without this, a bump could move the tag and leave the old digest in place — which pins
# the OLD image, silently, because a digest always wins over a tag.
DIGEST_STALE="$(grep -rEn 'percona/percona-distribution-postgresql:[^@[:space:]]+@sha256:[0-9a-f]+' \
  "$ROOT_DIR/k8s" "$ROOT_DIR/docker" 2>/dev/null | grep -v "@${PG_DIGEST}" || true)"
[[ -z "$DIGEST_STALE" ]] \
  && ok "every digest-pinned percona reference -> $PG_DIGEST" \
  || fail "postgres digest drift: $(head -1 <<<"$DIGEST_STALE")"

# ── 6. Self-host bundle ───────────────────────────────────────────────────────
# selfhost/ ships separately and was invisible to this checker, so a manifest bump used
# to leave it on the old major. Its compose defaults the image four times (postgres plus
# the config-guard / cert-init / db-init one-shots, which borrow the same image for bash,
# psql, openssl and GNU stat), and .env.example states it once more for the operator.
SELFHOST_STALE="$(grep -rn 'percona/percona-distribution-postgresql' \
  "$ROOT_DIR/selfhost/docker-compose.yml" "$ROOT_DIR/selfhost/.env.example" 2>/dev/null \
  | grep -v "$PG_IMAGE" || true)"
[[ -z "$SELFHOST_STALE" ]] \
  && ok "selfhost bundle -> $PG_IMAGE" \
  || fail "selfhost postgres image drift: $(head -1 <<<"$SELFHOST_STALE")"
grep -Fq "POSTGRES_IMAGE=${PG_IMAGE}@${PG_DIGEST}" "$ROOT_DIR/selfhost/.env.example" \
  && ok "selfhost release Postgres digest -> $PG_DIGEST" \
  || fail "selfhost/.env.example must pin POSTGRES_IMAGE to ${PG_IMAGE}@${PG_DIGEST}"

for image_contract in \
  "overlays/backups.yml|$SELFHOST_BACKUP_IMAGE" \
  "overlays/monitoring.yml|$SELFHOST_CADVISOR_IMAGE" \
  "overlays/monitoring.yml|$SELFHOST_VM_IMAGE" \
  "overlays/monitoring.yml|$SELFHOST_VL_IMAGE" \
  "overlays/monitoring.yml|$SELFHOST_FLUENT_BIT_IMAGE" \
  "overlays/monitoring.yml|$SELFHOST_GRAFANA_IMAGE" \
  "experimental/public-dashboard/auth.yml|$SELFHOST_KEYCLOAK_IMAGE"; do
  selfhost_file="${image_contract%%|*}"
  selfhost_image="${image_contract#*|}"
  grep -Fq "image: ${selfhost_image}" "$ROOT_DIR/selfhost/$selfhost_file" \
    && ok "selfhost/$selfhost_file -> $selfhost_image" \
    || fail "selfhost/$selfhost_file does not use manifest image $selfhost_image"
done

# ── 7. Hetzner hardened Percona base ──────────────────────────────────────────
# docker/hetzner/percona/Dockerfile rebuilds the image with a patched curl and the
# telemetry packages stripped. It has its own FROM, which drifted to a different tag than
# the manifest's before this check existed.
HETZNER_DF="$ROOT_DIR/docker/hetzner/percona/Dockerfile"
HETZNER_STALE="$(grep -n '^FROM ' "$HETZNER_DF" 2>/dev/null | grep -v "${PG_IMAGE}@${PG_DIGEST}" || true)"
[[ -z "$HETZNER_STALE" ]] \
  && ok "hetzner percona base -> $PG_IMAGE@$PG_DIGEST" \
  || fail "hetzner Dockerfile base drift: $(head -1 <<<"$HETZNER_STALE")"

# The image ships no percona_pg_telemetry, so naming it in shared_preload_libraries makes
# the server exit with FATAL: could not access file "percona_pg_telemetry".
PRELOAD_TELEMETRY="$(grep -rn 'shared_preload_libraries=[^[:space:]]*percona_pg_telemetry' \
  "$ROOT_DIR/docker" "$ROOT_DIR/k8s" "$ROOT_DIR/selfhost" 2>/dev/null || true)"
[[ -z "$PRELOAD_TELEMETRY" ]] \
  && ok "no shared_preload_libraries names percona_pg_telemetry" \
  || fail "percona_pg_telemetry preloaded but absent from the image — postgres will not start: $(head -1 <<<"$PRELOAD_TELEMETRY")"

# ── 8. Keycloak's Postgres (SSO tier, stock image, no pg_tde) ─────────────────
# Anchored to a real image reference (an `image:` key, a Dockerfile FROM, or a quoted
# literal in a guardrail test) so that prose ABOUT the pin does not read as drift.
KC_STALE="$(grep -rEn '(^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*|^FROM[[:space:]]+|")postgres:[0-9]+[^[:space:]"]*-alpine' \
  "$ROOT_DIR/docker" "$ROOT_DIR/k8s" "$ROOT_DIR/selfhost" "$ROOT_DIR/tests" 2>/dev/null \
  | grep -v "$KC_PG_IMAGE" || true)"
[[ -z "$KC_STALE" ]] \
  && ok "keycloak postgres -> $KC_PG_IMAGE" \
  || fail "keycloak postgres drift: $(head -1 <<<"$KC_STALE")"

KC_DIGEST_STALE="$(grep -rEn 'postgres:[0-9]+[^[:space:]"]*-alpine@sha256:[0-9a-f]+' \
  "$ROOT_DIR/docker" "$ROOT_DIR/k8s" "$ROOT_DIR/selfhost/experimental" 2>/dev/null | grep -v "@${KC_PG_DIGEST}" || true)"
[[ -z "$KC_DIGEST_STALE" ]] \
  && ok "keycloak postgres digest -> $KC_PG_DIGEST" \
  || fail "keycloak postgres digest drift: $(head -1 <<<"$KC_DIGEST_STALE")"

# postgres:18 moved its own default PGDATA to /var/lib/postgresql/18/docker and its VOLUME
# from /var/lib/postgresql/data up to /var/lib/postgresql. Any service that mounts
# /var/lib/postgresql/data WITHOUT naming PGDATA writes into an anonymous volume and loses
# the cluster on the next recreate. Verified against postgres:18.4-alpine: the marker row
# was gone and the container failed to restart. Every such service must set PGDATA.
for f in docker/docker-compose.traefik.yml selfhost/experimental/public-dashboard/auth.yml; do
  if grep -q 'keycloak' "$ROOT_DIR/$f" 2>/dev/null; then
    grep -q 'PGDATA' "$ROOT_DIR/$f" \
      && ok "$f names PGDATA explicitly (survives the postgres:18 default move)" \
      || fail "$f mounts a postgres:18 data volume without naming PGDATA — the cluster would land in an anonymous volume"
  fi
done

echo
if [[ "$FAILURES" -gt 0 ]]; then
  printf 'TOOLCHAIN DRIFT: %d failure(s) — fix the pins or update toolchain-manifest.yaml deliberately\n' "$FAILURES" >&2
  exit 1
fi
printf 'Toolchain manifest verified: no drift\n'
