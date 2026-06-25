#!/usr/bin/env bash
#
# verify-ci-pins.sh — prove, from the base and WITHOUT GitHub Actions, that every
# pinned CI tool download is live + hash-correct and actually executes, and that
# the workflows are structurally + shell valid.
#
# Why this exists: a workflow that merely *exists* in YAML proves nothing (the
# lefthook install was silently broken — dead URL + missing `curl -f` — for a long
# time because nothing ever ran it against reality). This re-downloads each pinned
# asset, recomputes its sha256, and runs it, so a lefthook-class breakage fails
# LOUDLY here instead of rotting unnoticed. Run it locally; wire it into CI later.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
HR_SHA="9af89fc71515a100421586dfdb3dc9c984fbf411"   # step-security/harden-runner v2.19.4
ZA_SHA="192e21d79ab29983730a13d1382995c2307fbcaa"   # zizmorcore/zizmor-action v0.5.7

hr() { printf '%s\n' "------------------------------------------------------------"; }

# verify_asset NAME URL EXPECTED_SHA256 ; on success sets global OUT to the file path
verify_asset() {
  local name="$1" url="$2" want="$3"
  local out="$tmp/${name//[^a-zA-Z0-9._-]/_}"
  OUT=""
  printf '  %-26s ' "$name"
  local code; code=$(curl -sL -o "$out" -w '%{http_code}' "$url" 2>/dev/null)
  if [ "$code" != "200" ]; then printf 'FAIL  HTTP %s (dead URL — the lefthook failure mode)\n' "$code"; fail=1; return 1; fi
  local got; got=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$got" != "$want" ]; then printf 'FAIL  sha256 drift\n      want %s\n      got  %s\n' "$want" "$got"; fail=1; return 1; fi
  printf 'OK    HTTP 200, sha256 matches pin\n'
  OUT="$out"; return 0
}

run_ok() { # description command...
  local desc="$1"; shift
  printf '  %-26s ' "$desc"
  if "$@" >/dev/null 2>&1; then printf 'OK    executed\n'; else printf 'FAIL  did not run\n'; fail=1; fi
}

hr; echo "[1] Pinned binaries: live URL + sha256 + actually runs"; hr

# lefthook (raw binary)
if verify_asset "lefthook 1.11.13" \
    "https://github.com/evilmartians/lefthook/releases/download/v1.11.13/lefthook_1.11.13_Linux_x86_64" \
    "d64379c1c0f74d10884c3487093608df973d37dcfbbc8aefa7e54564dcffb177"; then
  chmod +x "$OUT"; run_ok "  -> lefthook version" "$OUT" version
fi

# gitleaks (tar.gz)
if verify_asset "gitleaks 8.21.2" \
    "https://github.com/gitleaks/gitleaks/releases/download/v8.21.2/gitleaks_8.21.2_linux_x64.tar.gz" \
    "5bc41815076e6ed6ef8fbecc9d9b75bcae31f39029ceb55da08086315316e3ba"; then
  tar -xzf "$OUT" -C "$tmp" gitleaks 2>/dev/null && chmod +x "$tmp/gitleaks" && run_ok "  -> gitleaks version" "$tmp/gitleaks" version
fi

# container-structure-test (raw binary)
if verify_asset "container-struct v1.22.1" \
    "https://github.com/GoogleContainerTools/container-structure-test/releases/download/v1.22.1/container-structure-test-linux-amd64" \
    "fa35e89512a8978585f76cf41397956d2e3a30c62c2ad3fb857b1597074d14ca"; then
  chmod +x "$OUT"; run_ok "  -> container-struct version" "$OUT" version
fi

# oasdiff (tar.gz)
if verify_asset "oasdiff 1.20.0" \
    "https://github.com/oasdiff/oasdiff/releases/download/v1.20.0/oasdiff_1.20.0_linux_amd64.tar.gz" \
    "16f9a277edf8605cdb5595f8a7a4fbb474130c803a26099a1ff7e474b01c8580"; then
  tar -xzf "$OUT" -C "$tmp" oasdiff 2>/dev/null && chmod +x "$tmp/oasdiff" && run_ok "  -> oasdiff --version" "$tmp/oasdiff" --version
fi

# maestro (zip -> maestro/bin/maestro). JVM CLI: prove extraction + launcher present.
if verify_asset "maestro 1.39.13" \
    "https://github.com/mobile-dev-inc/maestro/releases/download/cli-1.39.13/maestro.zip" \
    "2751b2d76545e42ece4c308eb38b3bb16bb08b1651d6dcf8850c91c4a7306a13"; then
  unzip -q "$OUT" -d "$tmp/mz" 2>/dev/null
  printf '  %-26s ' "  -> maestro/bin/maestro"
  if [ -x "$tmp/mz/maestro/bin/maestro" ]; then printf 'OK    launcher present + executable\n'; else printf 'FAIL  launcher missing\n'; fail=1; fi
fi

hr; echo "[2] Pinned ACTION refs resolve to real immutable commits"; hr
for spec in "step-security/harden-runner:$HR_SHA" "zizmorcore/zizmor-action:$ZA_SHA"; do
  repo="${spec%%:*}"; sha="${spec##*:}"
  printf '  %-26s ' "$repo"
  if gh api "repos/$repo/commits/$sha" --jq '.sha' >/dev/null 2>&1; then printf 'OK    %s exists\n' "${sha:0:12}"; else printf 'FAIL  SHA not found\n'; fail=1; fi
done

hr; echo "[3] Every workflow parses + passes actionlint (schema + shellcheck)"; hr
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  printf '  %-40s ' "$(basename "$f")"
  if ! yq '.jobs' "$f" >/dev/null 2>&1; then printf 'FAIL  YAML parse\n'; fail=1; continue; fi
  printf 'parse OK\n'
done
# Resolve actionlint (CI uses v1.7.7). The shellcheck integration is the
# load-bearing half: without shellcheck on PATH actionlint silently SKIPS it —
# the exact false-green that hid 38 findings until act ran the real job. So a
# missing shellcheck is a FAIL here, not a skip. SHELLCHECK_OPTS must stay in
# sync with .github/workflows/actionlint.yml.
ACTIONLINT="$(command -v actionlint || true)"
[ -z "$ACTIONLINT" ] && [ -x /tmp/actionlint ] && ACTIONLINT=/tmp/actionlint
if [ -z "$ACTIONLINT" ]; then
  printf '  %-40s FAIL  actionlint not found (install v1.7.7 to match CI)\n' "actionlint"
  fail=1
elif ! command -v shellcheck >/dev/null 2>&1; then
  printf '  %-40s FAIL  shellcheck not on PATH — "+ shellcheck" half would be skipped\n' "actionlint"
  fail=1
else
  printf '  %-40s ' "actionlint + shellcheck (all)"
  if out=$(SHELLCHECK_OPTS="--exclude=SC2129" "$ACTIONLINT" .github/workflows/*.yml .github/workflows/*.yaml 2>&1); then
    printf 'OK\n'
  else
    printf 'FINDINGS\n'; printf '%s\n' "$out" | sed 's/^/      /'; fail=1
  fi
fi

hr; echo "[4] trustedDependencies guard: positive + negative"; hr
printf '  %-26s ' "clean tree passes"
if bash scripts/check-no-trusted-deps.sh >/dev/null 2>&1; then printf 'OK\n'; else printf 'FAIL\n'; fail=1; fi
printf '  %-26s ' "catches a planted key"
# Run a COPY of the guard inside an isolated tree (the guard derives its own
# ROOT_DIR from its location), with a planted trustedDependencies key.
mkdir -p "$tmp/neg/scripts"
cp scripts/check-no-trusted-deps.sh "$tmp/neg/scripts/"
printf '{"trustedDependencies":["x"]}' > "$tmp/neg/package.json"
if bash "$tmp/neg/scripts/check-no-trusted-deps.sh" >/dev/null 2>&1; then
  printf 'FAIL  guard is a no-op!\n'; fail=1
else
  printf 'OK    fails as designed\n'
fi

hr
if [ "$fail" -eq 0 ]; then echo "RESULT: all base-level proofs PASS"; else echo "RESULT: FAILURES above"; fi
exit "$fail"
