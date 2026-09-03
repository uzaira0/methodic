#!/usr/bin/env bash
# Run the parts of GitHub CI that are meaningful on a developer workstation.
#
# This intentionally does not emulate GitHub-only plumbing such as artifact
# upload, SARIF upload to the Security tab, PR annotations, or Actions cache
# restore/save. It does run the same underlying build, test, and scanner
# commands so failures can be reproduced before pushing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$ROOT_DIR/chronicle-web"
LOCAL_BIN_DIR="${CHRONICLE_LOCAL_BIN_DIR:-$ROOT_DIR/.local/bin}"
LOCAL_REPORT_DIR="${CHRONICLE_LOCAL_CI_REPORT_DIR:-}"
if [[ -n "$LOCAL_REPORT_DIR" && "$LOCAL_REPORT_DIR" != /* ]]; then
  LOCAL_REPORT_DIR="$PWD/$LOCAL_REPORT_DIR"
fi

export PATH="$LOCAL_BIN_DIR:$PATH"

usage() {
  cat <<'EOF'
Usage: scripts/local-ci.sh <job> [job...]

Fast jobs:
  preflight             Validate local toolchain and workspace basics
  architecture          Source ownership, dependency boundaries, negative fixtures
  web                   chronicle-web audit, checks, tests, build, size
  jvm-smoke             Gradle project list, OpenAPI validation, API/server tests, JaCoCo
  repo-automation       Compose config + repo guardrail scripts
  linkml-ssot           LinkML schema freshness and domain contract drift checks
  cue-k8s               CUE deployment profile vs rendered Kubernetes checks
  dead-code             chronicle-web knip dead-code analysis
  dependency-sbom       Backend CycloneDX SBOM generation
  license-compliance    Backend and frontend license checks
  detekt                Kotlin Detekt scan with the pinned CI CLI jar

Container/IaC jobs:
  selfhost              Turnkey setup, monitoring privacy, release bundle, supported matrix
  dockerfile-lint       Hadolint the Dockerfiles
  iac-scan              Checkov Dockerfile and compose scans
  container-structure   Build/test backend and frontend container structure
  http-smoke-stack      Build/start local smoke stack, run HTTP smoke, tear down

Operator evidence job:
  operator-secret       Operator access and local secret-custody preflight

Security/dependency jobs:
  depcheck-locks        Validate/optionally clean stale Dependency-Check locks
  gradle-depcheck       OWASP Dependency-Check with shared NVD update
  bun-audit             Bun high/critical dependency audit
  gitleaks              Full-history secrets scan across root and all submodules
  pmd                   PMD bug-pattern scan
  bearer                Bearer SAST data-flow scan
  osv                   OSV-Scanner recursive SARIF scan
  grype                 Grype recursive repository scan
  syft                  Syft SPDX JSON SBOM
  openapi-diff          oasdiff against BASE_SPEC and HEAD_SPEC

Slow/specialized jobs:
  pit                   PIT mutation test for chronicle-server
  fuzz                  Jazzer fuzz tests
  parity                Kotlin and TypeScript parity tests
  web-mutation          Stryker mutation tests
  android-unit          Android unit tests (collection modules + app)
  ios-verify            iOS contract freshness + simulator test suite (macOS)

Groups:
  fast                  preflight web jvm-smoke repo-automation linkml-ssot cue-k8s dead-code dependency-sbom license-compliance
  security              gradle-depcheck bun-audit detekt pmd bearer osv grype syft
  containers            selfhost dockerfile-lint iac-scan container-structure http-smoke-stack
  all                   fast security containers parity

Environment:
  NVD_API_KEY           Required for gradle-depcheck
  CHRONICLE_NVD_API_KEY_FILE
                        Optional private file containing NVD_API_KEY on line 1
  CHRONICLE_NVD_KEYCHAIN_SERVICE, CHRONICLE_NVD_KEYCHAIN_ACCOUNT
                        Optional macOS Keychain service/account override.
                        Default service: chronicle-nvd-api-key
  scripts/chronicle-store-nvd-api-key.sh
                        Safe one-time helper for installing the NVD key into
                        Keychain or a private file without printing it.
  SKIP_NVD_UPDATE=1     Reuse existing .dependency-check-data for gradle-depcheck
  CHRONICLE_LOCAL_BIN_DIR
                        Tool download/cache dir, default ./.local/bin
  CHRONICLE_LOCAL_CI_REPORT_DIR
                        Optional report directory for scanner outputs. When unset,
                        outputs stay at the GitHub Actions-compatible paths.
                        For operator-secret, the bundle is written directly to
                        this directory.
  BASE_SPEC, HEAD_SPEC  Inputs for openapi-diff
  GRYPE_FAIL_ON         Failure threshold for grype; empty means evidence-only
  CHRONICLE_LOCAL_CI_KEEP_GOING=1
                        Continue running requested top-level jobs after a
                        failure, then exit nonzero. Use for evidence collection
                        so later scanner artifacts are still produced.
  CHRONICLE_DEPCHECK_RERUN=1
                        Pass --rerun-tasks to Dependency-Check analysis so
                        reports are regenerated after scanner config changes.
  CHRONICLE_DEPCHECK_UPDATE_TIMEOUT_SECONDS
                        Timeout for fresh NVD update, default 3600. Set 0 to
                        disable only for supervised first-time cache seeding.
  CHRONICLE_DEPCHECK_UPDATE_LOG
                        Optional path for the redacted fresh NVD update log.
                        Default: dependency-check-update.log in the report dir.
  CHRONICLE_DEPCHECK_NVD_VALID_FOR_HOURS
                        Fresh update window, default 0 for release evidence.
  CHRONICLE_DEPCHECK_CLEAN_STALE_LOCKS=1
                        Remove stale .dependency-check-data/*.lock files before
                        a fresh update, but only when no Gradle/Dependency-Check
                        process is running. Default is fail-closed on locks.
EOF
}

log() {
  printf '\n[local-ci] %s\n' "$*"
}

run_with_timeout() {
  local seconds="$1"
  shift
  if [[ "$seconds" == "0" ]]; then
    "$@"
    return
  fi
  require_cmd python3 "install Python 3 or set CHRONICLE_DEPCHECK_UPDATE_TIMEOUT_SECONDS=0 for supervised runs"
  python3 - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys
import time

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
proc = subprocess.Popen(cmd, preexec_fn=os.setsid)
try:
    sys.exit(proc.wait(timeout=timeout))
except subprocess.TimeoutExpired:
    sys.stderr.write(f"[local-ci] command timed out after {int(timeout)}s: {' '.join(cmd)}\n")
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            sys.exit(124)
        time.sleep(0.5)
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    sys.exit(124)
PY
}

run_with_timeout_logged() {
  local seconds="$1"
  local log_file="$2"
  shift 2

  require_cmd python3 "install Python 3 or set CHRONICLE_DEPCHECK_UPDATE_TIMEOUT_SECONDS=0 for supervised runs"
  ensure_dir "$(dirname "$log_file")"
  : > "$log_file"

  if [[ "$seconds" == "0" ]]; then
    # python3 -c (not "python3 - <<heredoc"): a heredoc would replace the piped
    # command output as stdin, leaving the pipe unread — nothing logged and the
    # command blocks once the pipe buffer fills.
    "$@" 2>&1 | python3 -c '
import re
import sys

log_path = sys.argv[1]
pattern = re.compile(r"(?i)(NVD_API_KEY|nvdApiKey|apiKey)(\s*[:=]\s*)([^ \t\r\n]+)")

with open(log_path, "a", encoding="utf-8", errors="replace") as log:
    for line in sys.stdin:
        redacted = pattern.sub(r"\1\2[redacted]", line)
        sys.stdout.write(redacted)
        log.write(redacted)
' "$log_file"
    return "${PIPESTATUS[0]}"
  fi

  require_cmd python3 "install Python 3 or set CHRONICLE_DEPCHECK_UPDATE_TIMEOUT_SECONDS=0 for supervised runs"
  python3 - "$seconds" "$log_file" "$@" <<'PY'
import os
import re
import selectors
import signal
import subprocess
import sys
import time

timeout = float(sys.argv[1])
log_path = sys.argv[2]
cmd = sys.argv[3:]
redact_pattern = re.compile(r"(?i)(NVD_API_KEY|nvdApiKey|apiKey)(\s*[:=]\s*)([^ \t\r\n]+)")

def redact(text: str) -> str:
    return redact_pattern.sub(r"\1\2[redacted]", text)

def write(stream, log, text: str) -> None:
    redacted = redact(text)
    stream.write(redacted)
    stream.flush()
    log.write(redacted)
    log.flush()

with open(log_path, "a", encoding="utf-8", errors="replace") as log:
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        preexec_fn=os.setsid,
    )
    assert proc.stdout is not None
    assert proc.stderr is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ, sys.stdout)
    selector.register(proc.stderr, selectors.EVENT_READ, sys.stderr)
    deadline = time.monotonic() + timeout

    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0 and proc.poll() is None:
            msg = f"[local-ci] command timed out after {int(timeout)}s: {' '.join(cmd)}\n"
            write(sys.stderr, log, msg)
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            kill_deadline = time.monotonic() + 15
            while time.monotonic() < kill_deadline:
                if proc.poll() is not None:
                    break
                time.sleep(0.5)
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.wait()
            sys.exit(124)

        events = selector.select(timeout=max(0.1, min(1.0, remaining)))
        if not events:
            if proc.poll() is not None:
                for fileobj, stream in ((proc.stdout, sys.stdout), (proc.stderr, sys.stderr)):
                    rest = fileobj.read()
                    if rest:
                        write(stream, log, rest)
                    try:
                        selector.unregister(fileobj)
                    except KeyError:
                        pass
            continue

        for key, _ in events:
            line = key.fileobj.readline()
            if line:
                write(key.data, log, line)
            else:
                try:
                    selector.unregister(key.fileobj)
                except KeyError:
                    pass

    sys.exit(proc.wait())
PY
}

dependency_check_data_snapshot() {
  local output="$1"
  local data_dir="$ROOT_DIR/.dependency-check-data"
  ensure_dir "$(dirname "$output")"
  {
    printf 'timestamp_utc\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'data_dir\t%s\n' "$data_dir"
    if [[ ! -d "$data_dir" ]]; then
      printf 'status\tmissing\n'
      return
    fi
    printf 'status\tpresent\n'
    printf 'locks\t%s\n' "$(dependency_check_lock_listing | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'files:\n'
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      if stat -f '%z	%Sm	%N' "$file" >/dev/null 2>&1; then
        stat -f '%z	%Sm	%N' "$file"
      else
        stat -c '%s	%y	%n' "$file"
      fi
    done < <(find "$data_dir" -maxdepth 1 -type f -print 2>/dev/null | sort)
  } > "$output"
}

diagnose_dependency_check_data() {
  local data_dir="$ROOT_DIR/.dependency-check-data"
  if [[ ! -d "$data_dir" ]]; then
    return
  fi
  local lock_listing
  lock_listing="$(dependency_check_lock_listing)"
  if [[ -z "$lock_listing" ]]; then
    return
  fi

  printf '[local-ci] Dependency-Check lock file(s) present before fresh update:\n' >&2
  while IFS= read -r lock_file; do
    [[ -z "$lock_file" ]] && continue
    if stat -f '%Sm %N' "$lock_file" >/dev/null 2>&1; then
      stat -f '[local-ci]   %Sm %N' "$lock_file" >&2
    else
      stat -c '[local-ci]   %y %n' "$lock_file" >&2
    fi
  done <<<"$lock_listing"

  local active_processes
  active_processes="$(dependency_check_active_processes)"
  if [[ -n "$active_processes" ]]; then
    printf '[local-ci] refusing to touch Dependency-Check locks while related process(es) are running:\n%s\n' "$active_processes" >&2
    exit 2
  fi

  if [[ "${CHRONICLE_DEPCHECK_CLEAN_STALE_LOCKS:-0}" == "1" ]]; then
    while IFS= read -r lock_file; do
      [[ -z "$lock_file" ]] && continue
      rm -f -- "$lock_file"
      printf '[local-ci] removed stale Dependency-Check lock: %s\n' "$lock_file" >&2
    done <<<"$lock_listing"
  else
    cat >&2 <<'EOF'
[local-ci] refusing fresh Dependency-Check update with pre-existing lock files.
[local-ci] If no Gradle/Dependency-Check process is running and these are stale
[local-ci] locks from an interrupted update, rerun with:
[local-ci]   CHRONICLE_DEPCHECK_CLEAN_STALE_LOCKS=1 scripts/local-ci.sh gradle-depcheck
EOF
    exit 2
  fi
}

dependency_check_lock_listing() {
  local data_dir="$ROOT_DIR/.dependency-check-data"
  find "$data_dir" -maxdepth 1 -type f -name '*.lock' -print 2>/dev/null | sort || true
}

dependency_check_active_processes() {
  ps -axo pid=,ppid=,command= |
    grep -E 'dependencyCheck|dependency-check|org\.gradle|GradleDaemon|odc\.mv\.db|jsrepository\.json' |
    grep -v -E 'grep -E|scripts/local-ci\.sh' || true
}

require_cmd() {
  local cmd="$1"
  local hint="${2:-install $cmd and retry}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '[local-ci] missing required command: %s (%s)\n' "$cmd" "$hint" >&2
    exit 127
  fi
}

require_jdk21() {
  local java_bin
  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
    java_bin="$JAVA_HOME/bin/java"
  else
    require_cmd java "install JDK 21 and set JAVA_HOME"
    java_bin="$(command -v java)"
  fi

  local version major
  version="$("$java_bin" -version 2>&1 | awk -F '"' '/version/ { print $2; exit }')"
  major="${version%%.*}"
  if [[ "$major" == "1" ]]; then
    major="$(cut -d. -f2 <<<"$version")"
  fi
  if [[ -z "$major" || "$major" -lt 21 ]]; then
    printf '[local-ci] JDK 21+ is required; found java version %s at %s.\n' "${version:-unknown}" "$java_bin" >&2
    printf '[local-ci] Try: export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home\n' >&2
    exit 127
  fi
}

sha256_check() {
  local expected="$1"
  local file="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c -
  else
    printf '[local-ci] missing sha256sum/shasum for verifying %s\n' "$file" >&2
    exit 127
  fi
}

gradle() {
  "$ROOT_DIR/gradlew" "$@"
}

ensure_dir() {
  mkdir -p "$1"
}

report_path() {
  local default_path="$1"
  local report_name="$2"
  if [[ -n "$LOCAL_REPORT_DIR" ]]; then
    ensure_dir "$LOCAL_REPORT_DIR"
    printf '%s/%s\n' "$LOCAL_REPORT_DIR" "$report_name"
  else
    printf '%s\n' "$default_path"
  fi
}

copy_dependency_check_reports() {
  if [[ -z "$LOCAL_REPORT_DIR" ]]; then
    return 0
  fi

  local report_dir="$LOCAL_REPORT_DIR/dependency-check"
  local manifest="$LOCAL_REPORT_DIR/dependency-check-reports.txt"
  local count=0
  ensure_dir "$report_dir"
  : > "$manifest"

  while IFS= read -r -d '' report; do
    local rel safe_name dest
    rel="${report#$ROOT_DIR/}"
    safe_name="${rel//\//__}"
    dest="$report_dir/$safe_name"
    cp "$report" "$dest"
    printf '%s\t%s\n' "$rel" "${dest#$LOCAL_REPORT_DIR/}" >> "$manifest"
    count=$((count + 1))
  done < <(find "$ROOT_DIR" -path '*/build/reports/dependency-check-report.*' -type f -print0 | sort -z)

  if [[ "$count" -eq 0 ]]; then
    printf '[local-ci] no OWASP Dependency-Check reports found under */build/reports.\n' >&2
    return 1
  fi

  printf '[local-ci] copied %s OWASP Dependency-Check report(s) into %s\n' "$count" "$report_dir"
}

write_dependency_check_skip_report() {
  local reason="$1"
  local report_dir="$ROOT_DIR/build/reports/security"
  ensure_dir "$report_dir"
  {
    printf 'OWASP Dependency-Check did not run.\n'
    printf 'reason=%s\n' "$reason"
    printf 'mode=cache-only\n'
    printf 'required_followup=Run scheduled or manual Security Vulnerability Scan for fresh keyed NVD analysis.\n'
  } > "$report_dir/dependency-check-skipped.txt"
}

machine_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) printf '[local-ci] unsupported OS: %s\n' "$(uname -s)" >&2; exit 127 ;;
  esac
}

machine_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    arm64|aarch64) echo arm64 ;;
    *) printf '[local-ci] unsupported architecture: %s\n' "$(uname -m)" >&2; exit 127 ;;
  esac
}

download_asset() {
  local url="$1"
  local output="$2"
  require_cmd curl
  curl -fsSL \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    --retry-max-time 120 \
    --connect-timeout 20 \
    "$url" \
    -o "$output"
}

download_asset_with_checksum() {
  local asset_url="$1"
  local checksum_url="$2"
  local asset_name="$3"
  local output="$4"
  local checksum_file expected
  checksum_file="$(mktemp)"
  download_asset "$asset_url" "$output"
  download_asset "$checksum_url" "$checksum_file"
  expected="$(awk -v asset="$asset_name" '
    {
      if (NF == 1 && $1 ~ /^[0-9a-fA-F]{64}$/) {
        print $1
        exit
      }
      name=$NF
      sub(/^\*\//, "", name)
      sub(/^\*/, "", name)
      sub(/^\.\//, "", name)
      if (name == asset) {
        print $1
        exit
      }
    }
  ' "$checksum_file")"
  rm -f "$checksum_file"
  if [[ -z "$expected" ]]; then
    printf '[local-ci] could not find checksum for %s in %s\n' "$asset_name" "$checksum_url" >&2
    exit 1
  fi
  sha256_check "$expected" "$output"
}

extract_binary_from_tar() {
  local archive="$1"
  local binary_name="$2"
  local output="$3"
  local tmp_dir found
  tmp_dir="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmp_dir"
  found="$(find "$tmp_dir" -type f -name "$binary_name" -perm -111 | head -1)"
  if [[ -z "$found" ]]; then
    found="$(find "$tmp_dir" -type f -name "$binary_name" | head -1)"
  fi
  if [[ -z "$found" ]]; then
    printf '[local-ci] could not find %s in %s\n' "$binary_name" "$archive" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi
  mv "$found" "$output"
  chmod +x "$output"
  rm -rf "$tmp_dir"
}

extract_binary_from_zip() {
  local archive="$1"
  local binary_name="$2"
  local output="$3"
  local tmp_dir found
  require_cmd unzip
  tmp_dir="$(mktemp -d)"
  unzip -q "$archive" -d "$tmp_dir"
  found="$(find "$tmp_dir" -type f -name "$binary_name" -perm -111 | head -1)"
  if [[ -z "$found" ]]; then
    found="$(find "$tmp_dir" -type f -name "$binary_name" | head -1)"
  fi
  if [[ -z "$found" ]]; then
    printf '[local-ci] could not find %s in %s\n' "$binary_name" "$archive" >&2
    rm -rf "$tmp_dir"
    exit 1
  fi
  mv "$found" "$output"
  chmod +x "$output"
  rm -rf "$tmp_dir"
}

ensure_container_structure_test() {
  if command -v container-structure-test >/dev/null 2>&1; then
    return 0
  fi

  ensure_dir "$LOCAL_BIN_DIR"
  local version="v1.22.1"
  local os arch asset tmp
  os="$(machine_os)"
  arch="$(machine_arch)"
  case "$os-$arch" in
    darwin-amd64) asset="container-structure-test-darwin-amd64" ;;
    darwin-arm64) asset="container-structure-test-darwin-arm64" ;;
    linux-amd64) asset="container-structure-test-linux-amd64" ;;
    linux-arm64) asset="container-structure-test-linux-arm64" ;;
    *) printf '[local-ci] unsupported container-structure-test platform: %s-%s\n' "$os" "$arch" >&2; exit 127 ;;
  esac
  tmp="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/GoogleContainerTools/container-structure-test/releases/download/${version}/${asset}" \
    "https://github.com/GoogleContainerTools/container-structure-test/releases/download/${version}/checksums.txt" \
    "$asset" \
    "$tmp"
  mv "$tmp" "$LOCAL_BIN_DIR/container-structure-test"
  chmod +x "$LOCAL_BIN_DIR/container-structure-test"
}

ensure_hadolint() {
  local bin="$LOCAL_BIN_DIR/hadolint"
  if [[ -x "$bin" ]]; then
    return 0
  fi
  ensure_dir "$LOCAL_BIN_DIR"
  local version="v2.14.0"
  local os arch asset tmp
  os="$(machine_os)"
  arch="$(machine_arch)"
  case "$os-$arch" in
    linux-amd64) asset="hadolint-linux-x86_64" ;;
    linux-arm64) asset="hadolint-linux-arm64" ;;
    darwin-amd64) asset="hadolint-macos-x86_64" ;;
    darwin-arm64) asset="hadolint-macos-arm64" ;;
    *) printf '[local-ci] unsupported hadolint platform: %s-%s\n' "$os" "$arch" >&2; exit 127 ;;
  esac
  tmp="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/hadolint/hadolint/releases/download/${version}/${asset}" \
    "https://github.com/hadolint/hadolint/releases/download/${version}/${asset}.sha256" \
    "$asset" \
    "$tmp"
  mv "$tmp" "$bin"
  chmod +x "$bin"
}

ensure_ast_grep() {
  local bin="$LOCAL_BIN_DIR/ast-grep"
  if command -v ast-grep >/dev/null 2>&1 && ast-grep --version >/dev/null 2>&1; then
    return 0
  fi
  if [[ -x "$bin" ]]; then
    return 0
  fi

  ensure_dir "$LOCAL_BIN_DIR"
  local version="0.42.1"
  local os arch asset sha tmp
  os="$(machine_os)"
  arch="$(machine_arch)"
  case "$os-$arch" in
    darwin-amd64)
      asset="app-x86_64-apple-darwin.zip"
      sha="a038965bfd7fe44257c771cdf8918dc3467dd8ec0eef673b8b14f639b144cdbd"
      ;;
    darwin-arm64)
      asset="app-aarch64-apple-darwin.zip"
      sha="c3961d8e8a4ee0ce2d0d98c7beeb168bb331cdc766b53630118a7b6c4fd39015"
      ;;
    linux-amd64)
      asset="app-x86_64-unknown-linux-gnu.zip"
      sha="5de8b87cba67fc8dc3e239d54b6484802ad745a7ae3de76be4fe89661dc52657"
      ;;
    linux-arm64)
      asset="app-aarch64-unknown-linux-gnu.zip"
      sha="3ba383839044cf9817929435f5ce0027f91d06931e8efb32d942e58d73d92be5"
      ;;
    *) printf '[local-ci] unsupported ast-grep platform: %s-%s\n' "$os" "$arch" >&2; exit 127 ;;
  esac
  tmp="$(mktemp)"
  download_asset "https://github.com/ast-grep/ast-grep/releases/download/${version}/${asset}" "$tmp"
  sha256_check "$sha" "$tmp"
  extract_binary_from_zip "$tmp" ast-grep "$bin"
  rm -f "$tmp"
}

prepare_checkov_runtime() {
  if command -v checkov >/dev/null 2>&1 && checkov --version >/dev/null 2>&1; then
    return 0
  fi

  local expat_lib="/opt/homebrew/opt/expat/lib"
  if command -v checkov >/dev/null 2>&1 &&
    [[ -d "$expat_lib" ]] &&
    DYLD_LIBRARY_PATH="$expat_lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" checkov --version >/dev/null 2>&1; then
    export DYLD_LIBRARY_PATH="$expat_lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    log "using Homebrew expat for local Checkov Python runtime"
    return 0
  fi

  require_cmd python3 "install Python 3 to bootstrap Checkov"
  local version="3.3.0"
  local venv="$LOCAL_BIN_DIR/checkov-${version}-venv"
  local wrapper="$LOCAL_BIN_DIR/checkov"
  if [[ ! -x "$venv/bin/checkov" ]]; then
    log "bootstrapping Checkov ${version} into $venv"
    rm -rf "$venv"
    python3 -m venv "$venv"
    "$venv/bin/python" -m pip install --disable-pip-version-check --upgrade pip wheel
    "$venv/bin/python" -m pip install --disable-pip-version-check "checkov==${version}"
  fi
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
exec "$venv/bin/checkov" "\$@"
EOF
  chmod +x "$wrapper"
  hash -r 2>/dev/null || true
  checkov --version >/dev/null
}

ensure_pmd() {
  local version="7.9.0"
  local pmd_home="$LOCAL_BIN_DIR/pmd-${version}"
  if [[ -x "$pmd_home/bin/pmd" ]]; then
    return 0
  fi
  require_cmd unzip
  ensure_dir "$LOCAL_BIN_DIR"
  local zip tmp_dir
  zip="$(mktemp)"
  tmp_dir="$(mktemp -d)"
  download_asset "https://github.com/pmd/pmd/releases/download/pmd_releases%2F${version}/pmd-dist-${version}-bin.zip" "$zip"
  unzip -q "$zip" -d "$tmp_dir"
  rm -f "$zip"
  rm -rf "$pmd_home"
  mv "$tmp_dir/pmd-bin-${version}" "$pmd_home"
  rm -rf "$tmp_dir"
}

ensure_bearer() {
  local version="2.0.2"
  local bin="$LOCAL_BIN_DIR/bearer"
  if [[ -x "$bin" ]]; then
    return 0
  fi
  ensure_dir "$LOCAL_BIN_DIR"
  local os arch asset archive
  os="$(machine_os)"
  arch="$(machine_arch)"
  asset="bearer_${version}_${os}_${arch}.tar.gz"
  archive="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/Bearer/bearer/releases/download/v${version}/${asset}" \
    "https://github.com/Bearer/bearer/releases/download/v${version}/checksums.txt" \
    "$asset" \
    "$archive"
  extract_binary_from_tar "$archive" bearer "$bin"
  rm -f "$archive"
}

ensure_osv_scanner() {
  local version="v2.3.8"
  local bin="$LOCAL_BIN_DIR/osv-scanner"
  if [[ -x "$bin" ]]; then
    return 0
  fi
  ensure_dir "$LOCAL_BIN_DIR"
  local os arch asset tmp
  os="$(machine_os)"
  arch="$(machine_arch)"
  asset="osv-scanner_${os}_${arch}"
  tmp="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/google/osv-scanner/releases/download/${version}/${asset}" \
    "https://github.com/google/osv-scanner/releases/download/${version}/osv-scanner_SHA256SUMS" \
    "$asset" \
    "$tmp"
  mv "$tmp" "$bin"
  chmod +x "$bin"
}

ensure_grype() {
  local version="0.115.0"
  local bin="$LOCAL_BIN_DIR/grype"
  if [[ -x "$bin" ]]; then
    return 0
  fi
  ensure_dir "$LOCAL_BIN_DIR"
  local os arch asset archive
  os="$(machine_os)"
  arch="$(machine_arch)"
  asset="grype_${version}_${os}_${arch}.tar.gz"
  archive="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/anchore/grype/releases/download/v${version}/${asset}" \
    "https://github.com/anchore/grype/releases/download/v${version}/grype_${version}_checksums.txt" \
    "$asset" \
    "$archive"
  extract_binary_from_tar "$archive" grype "$bin"
  rm -f "$archive"
}

ensure_syft() {
  local version="1.46.0"
  local bin="$LOCAL_BIN_DIR/syft"
  if [[ -x "$bin" ]]; then
    return 0
  fi
  ensure_dir "$LOCAL_BIN_DIR"
  local os arch asset archive
  os="$(machine_os)"
  arch="$(machine_arch)"
  asset="syft_${version}_${os}_${arch}.tar.gz"
  archive="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/anchore/syft/releases/download/v${version}/${asset}" \
    "https://github.com/anchore/syft/releases/download/v${version}/syft_${version}_checksums.txt" \
    "$asset" \
    "$archive"
  extract_binary_from_tar "$archive" syft "$bin"
  rm -f "$archive"
}

ensure_oasdiff() {
  local version="1.20.0"
  local bin="$LOCAL_BIN_DIR/oasdiff"
  if [[ -x "$bin" ]]; then
    return 0
  fi
  ensure_dir "$LOCAL_BIN_DIR"
  local os arch asset archive
  os="$(machine_os)"
  arch="$(machine_arch)"
  if [[ "$os" == "darwin" ]]; then
    asset="oasdiff_${version}_darwin_all.tar.gz"
  else
    asset="oasdiff_${version}_${os}_${arch}.tar.gz"
  fi
  archive="$(mktemp)"
  download_asset_with_checksum \
    "https://github.com/oasdiff/oasdiff/releases/download/v${version}/${asset}" \
    "https://github.com/oasdiff/oasdiff/releases/download/v${version}/checksums.txt" \
    "$asset" \
    "$archive"
  extract_binary_from_tar "$archive" oasdiff "$bin"
  rm -f "$archive"
}

ensure_detekt() {
  if [[ -x "$LOCAL_BIN_DIR/detekt-cli-1.23.7-all.jar" ]]; then
    return 0
  fi
  require_cmd curl
  require_jdk21
  ensure_dir "$LOCAL_BIN_DIR"
  local version="1.23.7"
  local jar="$LOCAL_BIN_DIR/detekt-cli-${version}-all.jar"
  local sha256="84beded283012cb2b38bcaef4996452fcd6069d2e9ca74b50eaa79e0ad21897e"
  curl -fsSL --retry 3 \
    "https://github.com/detekt/detekt/releases/download/v${version}/detekt-cli-${version}-all.jar" \
    -o "$jar"
  sha256_check "$sha256" "$jar"
  chmod +x "$jar"
}

job_preflight() {
  "$ROOT_DIR/scripts/chronicle-preflight.sh"
}

job_architecture() {
  require_cmd python3 "install Python 3"
  python3 "$ROOT_DIR/scripts/check-architecture-boundaries.py" --self-test
  python3 "$ROOT_DIR/scripts/check-architecture-boundaries.py"
  python3 "$ROOT_DIR/scripts/check-selfhost-capabilities.py"
  python3 "$ROOT_DIR/tests/security/selfhost-monitoring.py"
}

job_selfhost() {
  require_cmd docker "install Docker with Compose v2"
  require_cmd python3 "install Python 3"
  python3 "$ROOT_DIR/tests/security/selfhost-monitoring.py"
  "$ROOT_DIR/tests/security/selfhost-release-bundle.sh"
}

job_web() {
  require_cmd bun "install Bun 1.3.x"
  ensure_ast_grep
  log "web dependency audit"
  (cd "$WEB_DIR" && bun audit --audit-level=high)
  log "web check"
  (cd "$WEB_DIR" && bun run check)
  log "web modern tests"
  (
    cd "$WEB_DIR"
    failed=0
    for dir in src/modern/lib src/modern/state src/modern/stores src/modern/features src/modern/components src/modern/routes; do
      if [[ -d "$dir" ]]; then
        echo "=== $dir ==="
        bun test --coverage "$dir" || failed=1
      fi
    done
    exit "$failed"
  )
  log "OpenAPI type generation check"
  (cd "$WEB_DIR" && bun run check:api-types)
  log "contract drift detection"
  (cd "$WEB_DIR" && bun test src/modern/state/contract-drift.test.ts)
  log "legacy compatibility tests"
  (
    cd "$WEB_DIR"
    failed=0
    for f in src/bun-legacy/*.test.*; do
      echo "--- $f ---"
      bun test "$f" || failed=1
    done
    exit "$failed"
  )
  log "web build"
  (cd "$WEB_DIR" && bun run build)
  log "bundle size"
  (cd "$WEB_DIR" && bun run size)
}

job_jvm_smoke() {
  require_jdk21
  log "Gradle project listing"
  gradle projects --no-daemon
  log "OpenAPI spec validation"
  gradle :chronicle-api:validateOpenApiSpec --build-cache --no-daemon
  log "chronicle-api tests"
  gradle :chronicle-api:test --build-cache --no-daemon
  log "chronicle-server tests"
  gradle :chronicle-server:test --build-cache --no-daemon
  log "JaCoCo report"
  gradle :chronicle-server:jacocoTestReport --build-cache --no-daemon
}

job_repo_automation() {
  job_architecture
  require_cmd docker
  log "Compose validation"
  local compose_env compose_override
  local docker_env_created=0
  compose_env="$(mktemp)"
  compose_override="$(mktemp)"
  cp "$ROOT_DIR/docker/.env.example" "$compose_env"
  {
    echo "CROWDSEC_BOUNCER_API_KEY=ci-crowdsec-key"
    echo "JWT_SECRET=ci-smoke-test-jwt-secret-not-for-production"
    echo "HAZELCAST_SERVER_PASSWORD=ci-hz-server"
    echo "HAZELCAST_CLIENT_PASSWORD=ci-hz-client"
    echo "MOBILE_SIGNING_SECRET=ci-mobile-signing"
    echo "MOBILE_SIGNING_ENABLED=true"
    echo "MOBILE_SIGNING_REQUIRED=true"
    echo "GRAFANA_ADMIN_PASSWORD=ci-grafana-admin"
  } >> "$compose_env"
  cat > "$compose_override" <<EOF
services:
  chronicle-backend:
    env_file:
      - "$compose_env"
EOF
  if [[ ! -e "$ROOT_DIR/docker/.env" ]]; then
    cp "$compose_env" "$ROOT_DIR/docker/.env"
    docker_env_created=1
  fi
  if ! docker compose --env-file "$compose_env" -f "$ROOT_DIR/docker/docker-compose.traefik.yml" -f "$compose_override" config -q; then
    if [[ "$docker_env_created" -eq 1 ]]; then
      rm -f "$ROOT_DIR/docker/.env"
    fi
    rm -f "$compose_env" "$compose_override"
    return 1
  fi
  if [[ "$docker_env_created" -eq 1 ]]; then
    rm -f "$ROOT_DIR/docker/.env"
  fi
  rm -f "$compose_env" "$compose_override"
  log "toolchain manifest verification"
  bash "$ROOT_DIR/scripts/verify-toolchain.sh"
  log "trusted dependency script guard"
  bash "$ROOT_DIR/scripts/check-no-trusted-deps.sh"
  log "silent failure hunter"
  bash "$ROOT_DIR/scripts/silent-failure-hunter.sh"
}

job_dead_code() {
  require_cmd bun "install Bun 1.3.x"
  (cd "$WEB_DIR" && bun run dead-code)
}

job_dependency_sbom() {
  require_jdk21
  gradle :chronicle-server:cyclonedxBom --no-daemon
}

job_dockerfile_lint() {
  ensure_hadolint
  hadolint "$ROOT_DIR/docker/Dockerfile.backend"
  hadolint "$ROOT_DIR/docker/Dockerfile.frontend.prod"
}

job_iac_scan() {
  prepare_checkov_runtime
  local dockerfile_report compose_report checkov_tmp
  dockerfile_report="$(report_path "$ROOT_DIR/checkov-dockerfile.sarif" "checkov-dockerfile.sarif")"
  compose_report="$(report_path "$ROOT_DIR/checkov-compose.sarif" "checkov-compose.sarif")"
  checkov_tmp="$(mktemp -d)"

  checkov -d "$ROOT_DIR/docker" \
    --framework dockerfile \
    --quiet \
    --skip-download \
    --output sarif \
    --output-file-path "$checkov_tmp/dockerfile"
  cp "$checkov_tmp/dockerfile/results_sarif.sarif" "$dockerfile_report"

  checkov -f "$ROOT_DIR/docker/docker-compose.traefik.yml" \
    --framework yaml \
    --quiet \
    --skip-download \
    --output sarif \
    --output-file-path "$checkov_tmp/compose"
  cp "$checkov_tmp/compose/results_sarif.sarif" "$compose_report"
  rm -rf "$checkov_tmp"
}

job_license_compliance() {
  require_jdk21
  require_cmd bun "install Bun 1.3.x"
  gradle :chronicle-server:checkLicense --no-daemon
  (cd "$WEB_DIR" && bun install --frozen-lockfile)
  bash "$ROOT_DIR/scripts/check-frontend-licenses.sh"
}

job_container_structure() {
  require_cmd docker
  ensure_container_structure_test
  docker build -f "$ROOT_DIR/docker/Dockerfile.backend" -t chronicle-backend:test "$ROOT_DIR"
  container-structure-test test --image chronicle-backend:test --config "$ROOT_DIR/tests/container/backend.yaml"
  docker build -f "$ROOT_DIR/docker/Dockerfile.frontend.prod" -t chronicle-frontend-prod:test "$ROOT_DIR"
  container-structure-test test --image chronicle-frontend-prod:test --config "$ROOT_DIR/tests/container/frontend-prod.yaml"
}

write_ci_smoke_files() {
  local env_file="$1"
  local override_file="$2"
  local secrets_dir="$3"
  local certs_dir="$4"
  local backend_port="$5"
  local frontend_port="$6"
  mkdir -p "$secrets_dir"
  printf '%s' 'chronicle_ci_test' > "$secrets_dir/postgres_password"
  printf '%s' 'ci-smoke-test-jwt-secret-not-for-production' > "$secrets_dir/jwt_secret"
  printf '%s' 'ci-hz-server' > "$secrets_dir/hazelcast_server_password"
  printf '%s' 'ci-hz-client' > "$secrets_dir/hazelcast_client_password"
  printf '%s' 'ci-mobile-signing-secret-not-for-production-32-bytes' > "$secrets_dir/mobile_signing_secret"
  printf '%s' 'ci-metrics-password-not-for-production-32-bytes' > "$secrets_dir/chronicle_security_metrics_password"
  mkdir -p "$certs_dir/ca" "$certs_dir/server"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=Chronicle local smoke CA" \
    -keyout "$certs_dir/ca/ca.key" \
    -out "$certs_dir/ca/ca.crt" >/dev/null 2>&1
  cat > "$certs_dir/server/server.cnf" <<'EOF'
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no

[req_distinguished_name]
CN=postgres

[v3_req]
subjectAltName=@alt_names

[alt_names]
DNS.1=postgres
DNS.2=localhost
IP.1=127.0.0.1
EOF
  openssl req -new -newkey rsa:2048 -nodes \
    -config "$certs_dir/server/server.cnf" \
    -keyout "$certs_dir/server/server.key" \
    -out "$certs_dir/server/server.csr" >/dev/null 2>&1
  openssl x509 -req -days 1 \
    -in "$certs_dir/server/server.csr" \
    -CA "$certs_dir/ca/ca.crt" \
    -CAkey "$certs_dir/ca/ca.key" \
    -CAcreateserial \
    -extensions v3_req \
    -extfile "$certs_dir/server/server.cnf" \
    -out "$certs_dir/server/server.crt" >/dev/null 2>&1
  # The CI smoke key is generated in a temporary directory and bind-mounted
  # read-only. It must be readable by the container user so Postgres can copy it
  # into its runtime directory and then chmod the runtime copy to 0600.
  chmod 644 "$certs_dir/server/server.key"
  cat > "$env_file" <<EOF
DOMAIN=localhost
CHRONICLE_PUBLIC_BASE_URL=https://localhost
TRAEFIK_NETWORK=traefik
TRAEFIK_ENTRYPOINT=web
POSTGRES_USER=chronicle
POSTGRES_PASSWORD=chronicle_ci_test
POSTGRES_DB=chronicle
# The smoke compose stack defaults tables to tde_heap, so its ephemeral database
# must initialize pg_tde and the already-mounted temporary file keyring.
PG_TDE_KEY_PROVIDER=file
JWT_SECRET=ci-smoke-test-jwt-secret-not-for-production
CHRONICLE_INTERNAL_WEB_SECRET=ci-smoke-test-internal-web-secret-not-for-production-32-bytes
HAZELCAST_SERVER_PASSWORD=ci-hz-server
HAZELCAST_CLIENT_PASSWORD=ci-hz-client
MOBILE_SIGNING_SECRET=ci-mobile-signing-secret-not-for-production-32-bytes
MOBILE_SIGNING_ENABLED=true
MOBILE_SIGNING_REQUIRED=true
CROWDSEC_BOUNCER_API_KEY=ci-crowdsec-key
GRAFANA_ADMIN_PASSWORD=ci-grafana-admin-not-for-production
CHRONICLE_SECURITY_COOKIE_SECURE=true
CHRONICLE_SECURITY_REQUIRE_MFA=true
# Synthetic CI assurance fixture; production deploy.sh requires separate live IdP evidence.
CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED=true
SMTP_ENABLED=false
VAULT_ENABLED=false
GIT_SHA=${GITHUB_SHA:-local}
EOF
  cat > "$override_file" <<EOF
services:
  postgres:
    environment:
      PGDATA: /data/db/pgdata
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U chronicle -d chronicle"]
      interval: 5s
      timeout: 5s
      retries: 30
      start_period: 60s
    volumes:
      - postgres_data:/data/db
      - postgres_tde_keyring:/var/lib/postgresql/tde-keyring
      - ./init-db-roles.sql:/docker-entrypoint-initdb.d/10-init-db-roles.sql:ro
      - ./init-db-encryption.sh:/docker-entrypoint-initdb.d/20-init-db-encryption.sh:ro
      - ./init-replication.sh:/docker-entrypoint-initdb.d/25-init-replication.sh:ro
      - ./init-audit-immutability.sh:/docker-entrypoint-initdb.d/30-init-audit-immutability.sh:ro
      - "$certs_dir/server/server.crt:/etc/postgres-ssl-src/server.crt:ro"
      - "$certs_dir/server/server.key:/etc/postgres-ssl-src/server.key:ro"
      - "$certs_dir/ca/ca.crt:/etc/postgres-ssl-src/ca.crt:ro"
      - ./postgres-ssl/pg_hba-ssl.conf:/data/db/pg_hba.conf:ro
  chronicle-backend:
    ports:
      - "${backend_port}:40320"
    networks:
      - chronicle-internal
      - chronicle-sso-broker
      - chronicle-backend-bridge
      - ci-smoke
    volumes:
      - audit_logs:/var/log/chronicle
      - "$certs_dir/ca/ca.crt:/app/ssl/ca.crt:ro"
      - ./rhizome-docker.yaml.template:/server/config/rhizome.yaml.template:ro
      - ./chronicle-auth.yaml.template:/server/config/chronicle-auth.yaml.template:ro
      - ./mail.yaml.template:/server/config/mail.yaml.template:ro
      - ./mobile-security.yaml.template:/server/config/mobile-security.yaml.template:ro
      - ./vault.yaml.template:/server/config/vault.yaml.template:ro
      - ./cors.yaml.template:/server/config/cors.yaml.template:ro
  chronicle-frontend:
    ports:
      - "${frontend_port}:8080"
    networks:
      - chronicle-internal
      - ci-smoke
networks:
  ci-smoke:
    driver: bridge
secrets:
  postgres_password:
    file: "$secrets_dir/postgres_password"
  jwt_secret:
    file: "$secrets_dir/jwt_secret"
  hazelcast_server_password:
    file: "$secrets_dir/hazelcast_server_password"
  hazelcast_client_password:
    file: "$secrets_dir/hazelcast_client_password"
  mobile_signing_secret:
    file: "$secrets_dir/mobile_signing_secret"
  chronicle_security_metrics_password:
    file: "$secrets_dir/chronicle_security_metrics_password"
EOF
}

job_http_smoke_stack() {
  require_cmd docker
  require_cmd curl
  require_cmd openssl
  local tmp_dir env_file override_file secrets_dir certs_dir compose_args
  local repo_env_file repo_env_created metrics_password metrics_status
  local backend_port frontend_port backend_url frontend_url
  backend_port="${CHRONICLE_CI_BACKEND_PORT:-40320}"
  frontend_port="${CHRONICLE_CI_FRONTEND_PORT:-8080}"
  if [[ ! "$backend_port" =~ ^[0-9]+$ ]] || (( 10#$backend_port < 1 || 10#$backend_port > 65535 )); then
    log "invalid CHRONICLE_CI_BACKEND_PORT: $backend_port"
    return 2
  fi
  if [[ ! "$frontend_port" =~ ^[0-9]+$ ]] || (( 10#$frontend_port < 1 || 10#$frontend_port > 65535 )); then
    log "invalid CHRONICLE_CI_FRONTEND_PORT: $frontend_port"
    return 2
  fi
  if [[ "$backend_port" == "$frontend_port" ]]; then
    log "CHRONICLE_CI_BACKEND_PORT and CHRONICLE_CI_FRONTEND_PORT must differ"
    return 2
  fi
  tmp_dir="$(mktemp -d)"
  env_file="$tmp_dir/ci-smoke.env"
  override_file="$tmp_dir/docker-compose.ci-smoke.yml"
  secrets_dir="$tmp_dir/secrets"
  certs_dir="$tmp_dir/postgres-ssl"
  backend_url="http://localhost:${backend_port}"
  frontend_url="http://localhost:${frontend_port}"
  write_ci_smoke_files "$env_file" "$override_file" "$secrets_dir" "$certs_dir" "$backend_port" "$frontend_port"
  repo_env_file="$ROOT_DIR/docker/.env"
  repo_env_created=0
  if [[ ! -e "$repo_env_file" ]]; then
    cp "$env_file" "$repo_env_file"
    repo_env_created=1
  fi
  compose_args=(--env-file "$env_file" -f "$ROOT_DIR/docker/docker-compose.traefik.yml" -f "$override_file")

  # Freeze these function-local paths now; they are out of scope when the
  # process-level EXIT trap runs after the selected job returns.
  # shellcheck disable=SC2064
  trap "docker compose --env-file '$env_file' -f '$ROOT_DIR/docker/docker-compose.traefik.yml' -f '$override_file' down -v --remove-orphans >/dev/null 2>&1 || true; if [ '$repo_env_created' = '1' ]; then rm -f '$repo_env_file'; fi; rm -rf '$tmp_dir'" EXIT

  docker build -f "$ROOT_DIR/docker/Dockerfile.backend" -t chronicle-backend:test "$ROOT_DIR"
  docker build -f "$ROOT_DIR/docker/Dockerfile.frontend.prod" -t chronicle-frontend-prod:test "$ROOT_DIR"
  if ! docker compose "${compose_args[@]}" up -d postgres chronicle-backend chronicle-frontend; then
    docker compose "${compose_args[@]}" logs postgres --tail=160 || true
    docker compose "${compose_args[@]}" logs chronicle-backend --tail=160 || true
    docker compose "${compose_args[@]}" ps || true
    return 1
  fi

  log "waiting for backend"
  # A first boot applies the full Flyway corpus onto encrypted tables. Keep this
  # bounded, but allow enough time for a cold runner rather than racing startup.
  for i in $(seq 1 60); do
    if curl -sf "${backend_url}/chronicle/internal/health/ready" >/dev/null 2>&1; then
      break
    fi
    if [[ "$i" -eq 60 ]]; then
      docker compose "${compose_args[@]}" logs postgres --tail=160
      docker compose "${compose_args[@]}" logs chronicle-backend --tail=100
      exit 1
    fi
    sleep 5
  done

  metrics_password=$(<"$secrets_dir/chronicle_security_metrics_password")
  metrics_status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --user "chronicle-metrics:$metrics_password" \
    "${backend_url}/prometheus/" 2>/dev/null || true)
  if [[ "$metrics_status" != "200" ]]; then
    log "authenticated metrics smoke failed with HTTP ${metrics_status:-000}"
    docker compose "${compose_args[@]}" logs chronicle-backend --tail=100
    return 1
  fi

  log "waiting for frontend"
  for i in $(seq 1 12); do
    if curl -sf "${frontend_url}/health" >/dev/null 2>&1; then
      break
    fi
    if [[ "$i" -eq 12 ]]; then
      docker compose "${compose_args[@]}" logs chronicle-frontend --tail=100
      exit 1
    fi
    sleep 5
  done

  "$ROOT_DIR/scripts/smoke-test.sh" "$backend_url" "$frontend_url"
}

job_pit() {
  require_jdk21
  gradle :chronicle-server:pitest -PpitMutationThreshold=50
}

job_fuzz() {
  require_jdk21
  gradle :chronicle-server:test --tests "*FuzzTest" -Djazzer.maxRunsPerTarget=10000
}

job_parity() {
  require_jdk21
  require_cmd bun "install Bun 1.3.x"
  gradle :chronicle-server:test --tests "*ParityTest"
  (cd "$WEB_DIR" && bun install --frozen-lockfile && bun test src/modern/test/parity.test.ts)
}

job_android_unit() {
  require_jdk21
  log "Android unit tests (library modules + app play-debug variant)"
  # Library modules (collection-*, including the collection-contracts boundary
  # gate) expose testDebugUnitTest; the flavored app module exposes
  # testPlayDebugUnitTest. Together this runs every JVM unit test in the repo.
  (cd "$ROOT_DIR/chronicle" && ./gradlew testDebugUnitTest testPlayDebugUnitTest --no-daemon --build-cache)
}

job_ios_verify() {
  require_cmd python3
  require_cmd xcodebuild "run on macOS with Xcode installed"
  require_cmd rg "install ripgrep (brew install ripgrep)"
  log "iOS generated contract freshness"
  (cd "$ROOT_DIR/chronicle-ios" && python3 scripts/generate-ios-contracts.py --check)
  log "iOS simulator test suite (no-AWS harness; physical-device checks skipped)"
  local destination="${SIMULATOR_DESTINATION:-}"
  if [[ -z "$destination" ]]; then
    # Pick any available iPhone simulator: runner images and dev machines ship
    # different device sets, and a hard-coded name rots (e.g. "iPhone 17e").
    local sim_name
    sim_name="$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone[^(]*\)(.*/\1/p' | sed 's/ *$//' | head -1)"
    if [[ -z "$sim_name" ]]; then
      printf '[local-ci] no available iPhone simulator found\n' >&2
      return 1
    fi
    destination="platform=iOS Simulator,name=$sim_name"
  fi
  RUN_PHYSICAL_DEVICE=0 SIMULATOR_DESTINATION="$destination" \
    REPORT_DIR="$ROOT_DIR/chronicle-ios/build/ios-no-aws" \
    "$ROOT_DIR/chronicle-ios/scripts/ios-no-aws-verify.sh"
}

job_gitleaks() {
  # Local twin of each repo's gitleaks.yml "Scan for secrets" workflow (full
  # git-history scan). The private repos get no free Actions minutes, so this
  # is the proof gate that actually runs. Known historical/false-positive
  # fingerprints live in tests/security/gitleaks-ignore/<name>.gitleaksignore;
  # only NEW findings fail the job.
  require_cmd gitleaks "install gitleaks (brew install gitleaks)"
  local repo name ignore failed=()
  for repo in . chronicle chronicle-api chronicle-ios chronicle-models \
    chronicle-server chronicle-web rhizome rhizome-client; do
    name="$repo"
    [[ "$repo" == "." ]] && name="methodic-root"
    ignore="$ROOT_DIR/tests/security/gitleaks-ignore/$name.gitleaksignore"
    [[ -f "$ignore" ]] || ignore="/dev/null"
    log "gitleaks: $name"
    if ! (cd "$ROOT_DIR/$repo" && \
      gitleaks git --no-banner --redact --gitleaks-ignore-path "$ignore" .); then
      failed+=("$name")
    fi
  done
  if ((${#failed[@]} > 0)); then
    printf '[local-ci] gitleaks found leaks in: %s\n' "${failed[*]}" >&2
    return 1
  fi
}

job_depcheck_locks() {
  local lock_listing active_processes
  lock_listing="$(dependency_check_lock_listing)"
  if [[ -z "$lock_listing" ]]; then
    printf '[local-ci] no Dependency-Check lock files present.\n'
    return 0
  fi

  active_processes="$(dependency_check_active_processes)"
  printf '[local-ci] Dependency-Check lock file(s) present:\n' >&2
  while IFS= read -r lock_file; do
    [[ -z "$lock_file" ]] && continue
    if stat -f '%Sm %N' "$lock_file" >/dev/null 2>&1; then
      stat -f '[local-ci]   %Sm %N' "$lock_file" >&2
    else
      stat -c '[local-ci]   %y %n' "$lock_file" >&2
    fi
  done <<<"$lock_listing"

  if [[ -n "$active_processes" ]]; then
    printf '[local-ci] related process(es) are active; not cleaning locks:\n%s\n' "$active_processes" >&2
    return 2
  fi

  if [[ "${CHRONICLE_DEPCHECK_CLEAN_STALE_LOCKS:-0}" != "1" ]]; then
    cat >&2 <<'EOF'
[local-ci] no related Gradle/Dependency-Check process is running.
[local-ci] To remove stale locks before a keyed fresh update, rerun:
[local-ci]   CHRONICLE_DEPCHECK_CLEAN_STALE_LOCKS=1 scripts/local-ci.sh depcheck-locks
EOF
    return 2
  fi

  while IFS= read -r lock_file; do
    [[ -z "$lock_file" ]] && continue
    rm -f -- "$lock_file"
    printf '[local-ci] removed stale Dependency-Check lock: %s\n' "$lock_file" >&2
  done <<<"$lock_listing"

  if [[ -n "$(dependency_check_lock_listing)" ]]; then
    printf '[local-ci] Dependency-Check lock cleanup incomplete.\n' >&2
    return 1
  fi
  printf '[local-ci] Dependency-Check lock cleanup complete.\n'
}

job_gradle_depcheck() {
  require_jdk21
  # Loads from env, a private file, macOS Keychain, or pass without printing.
  # The later check still fails closed when no key is available.
  # shellcheck source=/dev/null
  source "$ROOT_DIR/scripts/chronicle-load-nvd-api-key.sh"
  if [[ "${SKIP_NVD_UPDATE:-0}" != "1" && -z "${NVD_API_KEY:-}" ]]; then
    printf '[local-ci] NVD_API_KEY is required for gradle-depcheck.\n' >&2
    exit 2
  fi
  if [[ "${SKIP_NVD_UPDATE:-0}" != "1" ]]; then
    diagnose_dependency_check_data
    local update_timeout="${CHRONICLE_DEPCHECK_UPDATE_TIMEOUT_SECONDS:-3600}"
    local nvd_valid_for_hours="${CHRONICLE_DEPCHECK_NVD_VALID_FOR_HOURS:-0}"
    local update_log="${CHRONICLE_DEPCHECK_UPDATE_LOG:-$(report_path "$ROOT_DIR/build/reports/dependency-check-update.log" "dependency-check-update.log")}"
    local update_snapshot_before
    local update_snapshot_after
    update_snapshot_before="$(report_path "$ROOT_DIR/build/reports/dependency-check-update-data-before.txt" "dependency-check-update-data-before.txt")"
    update_snapshot_after="$(report_path "$ROOT_DIR/build/reports/dependency-check-update-data-after.txt" "dependency-check-update-data-after.txt")"
    local update_args=(
      dependencyCheckUpdateShared
      --no-daemon
      --max-workers=1
      --console=plain
      "-PdependencyCheckNvdValidForHours=$nvd_valid_for_hours"
    )
    if [[ -n "${CHRONICLE_DEPCHECK_NVD_DELAY_MILLIS:-}" ]]; then
      update_args+=("-PdependencyCheckNvdDelayMillis=$CHRONICLE_DEPCHECK_NVD_DELAY_MILLIS")
    fi
    if [[ -n "${CHRONICLE_DEPCHECK_NVD_MAX_RETRY_COUNT:-}" ]]; then
      update_args+=("-PdependencyCheckNvdMaxRetryCount=$CHRONICLE_DEPCHECK_NVD_MAX_RETRY_COUNT")
    fi
    if [[ -n "${CHRONICLE_DEPCHECK_NVD_RESULTS_PER_PAGE:-}" ]]; then
      update_args+=("-PdependencyCheckNvdResultsPerPage=$CHRONICLE_DEPCHECK_NVD_RESULTS_PER_PAGE")
    fi
    if [[ -n "${CHRONICLE_DEPCHECK_GRADLE_LOG_LEVEL:-}" ]]; then
      update_args+=("$CHRONICLE_DEPCHECK_GRADLE_LOG_LEVEL")
    fi
    printf '[local-ci] running fresh Dependency-Check NVD update with validForHours=%s timeout=%ss\n' \
      "$nvd_valid_for_hours" "$update_timeout"
    printf '[local-ci] Dependency-Check update log: %s\n' "$update_log"
    dependency_check_data_snapshot "$update_snapshot_before"
    local update_status=0
    run_with_timeout_logged "$update_timeout" "$update_log" "$ROOT_DIR/gradlew" "${update_args[@]}" || update_status=$?
    if [[ "$update_status" -ne 0 ]]; then
      dependency_check_data_snapshot "$update_snapshot_after"
      printf '[local-ci] Dependency-Check update failed with status %s.\n' "$update_status" >&2
      printf '[local-ci] Data snapshots: %s %s\n' "$update_snapshot_before" "$update_snapshot_after" >&2
      printf '[local-ci] Redacted update log: %s\n' "$update_log" >&2
      return "$update_status"
    fi
    dependency_check_data_snapshot "$update_snapshot_after"
  elif [[ ! -s "$ROOT_DIR/.dependency-check-data/odc.mv.db" ]]; then
    if [[ "${CHRONICLE_DEPCHECK_ALLOW_MISSING_CACHE:-0}" == "1" ]]; then
      local reason="SKIP_NVD_UPDATE=1 requested but no warmed .dependency-check-data/odc.mv.db cache was restored"
      printf '[local-ci] %s; writing skip report.\n' "$reason" >&2
      write_dependency_check_skip_report "$reason"
      return 0
    fi
    printf '[local-ci] SKIP_NVD_UPDATE=1 requires a warmed %s cache.\n' "$ROOT_DIR/.dependency-check-data/odc.mv.db" >&2
    exit 2
  fi
  local status=0
  local depcheck_args=(-PdependencyCheckAutoUpdate=false)
  if [[ "${SKIP_NVD_UPDATE:-0}" == "1" ]]; then
    depcheck_args+=(-PdependencyCheckOffline=true)
  fi
  local gradle_task_args=(dependencyCheckAll)
  if [[ "${CHRONICLE_DEPCHECK_RERUN:-0}" == "1" ]]; then
    gradle_task_args+=(--rerun-tasks)
  fi
  gradle "${gradle_task_args[@]}" --no-daemon --max-workers=1 "${depcheck_args[@]}" || status=$?
  copy_dependency_check_reports || {
    if [[ "$status" -eq 0 ]]; then
      status=1
    fi
  }
  return "$status"
}

job_bun_audit() {
  require_cmd bun "install Bun 1.3.x"
  local json_report text_report
  json_report="$(report_path "$WEB_DIR/bun-audit-report.json" "bun-audit-report.json")"
  text_report="$(report_path "$WEB_DIR/bun-audit-output.txt" "bun-audit-output.txt")"
  (cd "$WEB_DIR" && bun install --frozen-lockfile)
  (cd "$WEB_DIR" && bun audit --json > "$json_report")
  (
    cd "$WEB_DIR"
    bun audit --audit-level=high > "$text_report" 2>&1 || audit_exit=$?
    cat "$text_report"
    exit "${audit_exit:-0}"
  )
}

job_detekt() {
  ensure_detekt
  local sarif_report html_report
  sarif_report="$(report_path "$ROOT_DIR/detekt-results.sarif" "detekt-results.sarif")"
  html_report="$(report_path "$ROOT_DIR/detekt-results.html" "detekt-results.html")"
  java -jar "$LOCAL_BIN_DIR/detekt-cli-1.23.7-all.jar" \
    --input "$ROOT_DIR/chronicle-server/src,$ROOT_DIR/chronicle-api/src,$ROOT_DIR/rhizome/src" \
    --config "$ROOT_DIR/detekt.yml" \
    --baseline "$ROOT_DIR/detekt-baseline.xml" \
    --report "sarif:$sarif_report" \
    --report "html:$html_report" \
    --build-upon-default-config
}

job_pmd() {
  require_jdk21
  ensure_pmd
  "$LOCAL_BIN_DIR/pmd-7.9.0/bin/pmd" check \
    -d "$ROOT_DIR/chronicle-server/src/main/kotlin" \
    -d "$ROOT_DIR/chronicle-api/src/main/kotlin" \
    -R rulesets/java/quickstart.xml \
    -f text
}

job_bearer() {
  ensure_bearer
  local sarif_report
  sarif_report="$(report_path "$ROOT_DIR/bearer-results.sarif" "bearer-results.sarif")"
  BEARER_SCANNER=sast \
    BEARER_FORMAT=sarif \
    BEARER_OUTPUT="$sarif_report" \
    BEARER_HIDE_PROGRESS_BAR=true \
    bearer scan "$ROOT_DIR"
  python3 - "$sarif_report" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text())
for run in doc.get("runs", []):
    if run.get("results") is None:
        run["results"] = []
path.write_text(json.dumps(doc, indent=2) + "\n")
PY
}

job_osv() {
  ensure_osv_scanner
  local sarif_report
  sarif_report="$(report_path "$ROOT_DIR/osv-results.sarif" "osv-results.sarif")"
  osv-scanner scan source \
    --recursive \
    --experimental-exclude 'r:(^|/)gradle($|/)' \
    --format=sarif \
    --output-file="$sarif_report" \
    "$ROOT_DIR"
}

job_grype() {
  ensure_grype
  local fail_on="${GRYPE_FAIL_ON-high}"
  local sarif_report
  sarif_report="$(report_path "$ROOT_DIR/grype-results.sarif" "grype-results.sarif")"
  if [[ -n "$fail_on" ]]; then
    grype --config "$ROOT_DIR/.grype.yaml" "dir:$ROOT_DIR" \
      --fail-on "$fail_on" -o "sarif=$sarif_report"
  else
    grype --config "$ROOT_DIR/.grype.yaml" "dir:$ROOT_DIR" \
      -o "sarif=$sarif_report"
  fi
}

job_syft() {
  ensure_syft
  local sbom_report
  sbom_report="$(report_path "$ROOT_DIR/sbom-spdx.json" "sbom-spdx.json")"
  syft "$ROOT_DIR" -o spdx-json="$sbom_report"
}

job_openapi_diff() {
  ensure_oasdiff
  local base_spec="${BASE_SPEC:-$ROOT_DIR/base/chronicle-api/chronicle.yaml}"
  local head_spec="${HEAD_SPEC:-$ROOT_DIR/chronicle-api/chronicle.yaml}"
  if [[ ! -f "$base_spec" ]]; then
    printf '[local-ci] missing BASE_SPEC: %s\n' "$base_spec" >&2
    exit 1
  fi
  if [[ ! -f "$head_spec" ]]; then
    printf '[local-ci] missing HEAD_SPEC: %s\n' "$head_spec" >&2
    exit 1
  fi
  echo "Comparing $base_spec vs $head_spec"
  oasdiff breaking "$base_spec" "$head_spec" --format text
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## API Changelog"
      oasdiff changelog "$base_spec" "$head_spec" --format text
    } >> "$GITHUB_STEP_SUMMARY"
  else
    oasdiff changelog "$base_spec" "$head_spec" --format text
  fi
}

job_linkml_ssot() {
  require_cmd python3 "install Python 3"
  local models_dir="${CHRONICLE_MODELS_DIR:-}"
  if [[ -z "$models_dir" && -f "$ROOT_DIR/chronicle-models/generated/domain-contracts/chronicle-domain-contracts.json" ]]; then
    models_dir="$ROOT_DIR/chronicle-models"
  elif [[ -z "$models_dir" && -f "$ROOT_DIR/../chronicle-models/generated/domain-contracts/chronicle-domain-contracts.json" ]]; then
    models_dir="$ROOT_DIR/../chronicle-models"
  fi
  if [[ -n "$models_dir" ]]; then
    CHRONICLE_MODELS_DIR="$models_dir" "$ROOT_DIR/tests/security/schema-guardrails.sh"
    CHRONICLE_MODELS_DIR="$models_dir" "$ROOT_DIR/tests/security/domain-contract-guardrails.sh"
  else
    "$ROOT_DIR/tests/security/schema-guardrails.sh"
    "$ROOT_DIR/tests/security/domain-contract-guardrails.sh"
  fi
}

job_cue_k8s() {
  require_cmd cue "brew install cue-lang/tap/cue"
  if ! command -v kubectl >/dev/null 2>&1 && ! command -v kustomize >/dev/null 2>&1; then
    printf '[local-ci] missing required command: kubectl or kustomize (install kubectl or kustomize)\n' >&2
    exit 127
  fi
  local report_dir="${LOCAL_REPORT_DIR:-/tmp/chronicle-cue-k8s}"
  "$ROOT_DIR/tests/security/cue-k8s-guardrails.sh" "$report_dir"
}

job_operator_secret() {
  local report_dir="${LOCAL_REPORT_DIR:-/tmp/chronicle-operator-secret-evidence}"
  CHRONICLE_OPERATOR_SECRET_REPORT_DIR="$report_dir" \
    "$ROOT_DIR/scripts/chronicle-operator-secret-evidence.sh"
}

job_web_mutation() {
  require_cmd bun "install Bun 1.3.x"
  (cd "$WEB_DIR" && bun run test:mutate)
}

run_job() {
  case "$1" in
    preflight) job_preflight ;;
    architecture) job_architecture ;;
    web) job_web ;;
    jvm-smoke) job_jvm_smoke ;;
    repo-automation) job_repo_automation ;;
    linkml-ssot) job_linkml_ssot ;;
    cue-k8s) job_cue_k8s ;;
    dead-code) job_dead_code ;;
    dependency-sbom) job_dependency_sbom ;;
    selfhost) job_selfhost ;;
    dockerfile-lint) job_dockerfile_lint ;;
    iac-scan) job_iac_scan ;;
    license-compliance) job_license_compliance ;;
    container-structure) job_container_structure ;;
    http-smoke-stack) job_http_smoke_stack ;;
    operator-secret) job_operator_secret ;;
    pit) job_pit ;;
    fuzz) job_fuzz ;;
    parity) job_parity ;;
    android-unit) job_android_unit ;;
    ios-verify) job_ios_verify ;;
    gitleaks) job_gitleaks ;;
    depcheck-locks) job_depcheck_locks ;;
    gradle-depcheck) job_gradle_depcheck ;;
    bun-audit) job_bun_audit ;;
    detekt) job_detekt ;;
    pmd) job_pmd ;;
    bearer) job_bearer ;;
    osv) job_osv ;;
    grype) job_grype ;;
    syft) job_syft ;;
    openapi-diff) job_openapi_diff ;;
    web-mutation) job_web_mutation ;;
    fast)
      run_job preflight
      run_job architecture
      run_job web
      run_job jvm-smoke
      run_job repo-automation
      run_job linkml-ssot
      run_job cue-k8s
      run_job dead-code
      run_job dependency-sbom
      run_job license-compliance
      ;;
    security)
      run_job gradle-depcheck
      run_job bun-audit
      run_job detekt
      run_job pmd
      run_job bearer
      run_job osv
      run_job grype
      run_job syft
      ;;
    containers)
      run_job selfhost
      run_job dockerfile-lint
      run_job iac-scan
      run_job container-structure
      run_job http-smoke-stack
      ;;
    all)
      run_job fast
      run_job security
      run_job containers
      run_job parity
      ;;
    -h|--help|help) usage ;;
    *) printf '[local-ci] unknown job: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
}

if [[ "$#" -eq 0 ]]; then
  usage
  exit 2
fi

failures=0
for job in "$@"; do
  log "job: $job"
  if [[ "${CHRONICLE_LOCAL_CI_KEEP_GOING:-0}" == "1" ]]; then
    status=0
    run_job "$job" || status=$?
    if [[ "$status" -ne 0 ]]; then
      failures=$((failures + 1))
      printf '[local-ci] job failed: %s status=%s\n' "$job" "$status" >&2
    fi
  else
    run_job "$job"
  fi
done

if [[ "${CHRONICLE_LOCAL_CI_KEEP_GOING:-0}" == "1" && "$failures" -gt 0 ]]; then
  printf '[local-ci] %s job(s) failed\n' "$failures" >&2
  exit 1
fi
