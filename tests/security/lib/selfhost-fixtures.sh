#!/usr/bin/env bash

export CHRONICLE_RECONCILE_ENABLED=false

copy_selfhost_setup_fixture() {
  local destination="$1"
  mkdir -p "$destination"
  cp "${ROOT_DIR}/selfhost/chronicle" "${ROOT_DIR}/selfhost/guard-config.sh" \
    "${ROOT_DIR}/selfhost/network-policy.sh" "${ROOT_DIR}/selfhost/network-subnet.py" \
    "${ROOT_DIR}/selfhost/.env.example" "${ROOT_DIR}/selfhost/release-signing.pub" "$destination/"
  cp -R "${ROOT_DIR}/selfhost/chronicle_ops" "$destination/"
  chmod 0755 "${destination}/chronicle"
}

make_selfhost_setup_fixture() {
  local case_dir="$1"
  copy_selfhost_setup_fixture "${case_dir}/selfhost"
  mkdir -p "${case_dir}/bin"
  cat >"${case_dir}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'compose ls --all --format json' ]]; then
  printf '[]\n'
elif [[ "${1:-}" == run ]]; then
  cat >/dev/null
  printf '%s\n' "${SELFHOST_FIXTURE_BCRYPT:-\$2a\$14\$syntheticbcryptvalueabcdefghijklmnopqrstuv0123456789ABCDE}"
fi
exit 0
SH
  cat >"${case_dir}/bin/crontab" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -l ]]; then echo "no crontab for fixture" >&2; exit 1; fi
cat >/dev/null
SH
  cat >"${case_dir}/bin/openssl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'rand -base64 32' ]] || exit 91
printf '%s\n' "${SELFHOST_FIXTURE_GENERATED:-synthetic-generated-value-for-operator-test-only}"
SH
  cat >"${case_dir}/bin/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  '-4 -o addr show') printf '%s\n' '1: lo inet 127.0.0.1/8 scope host lo' ;;
  '-4 -j route show table all'|'-6 -j route show table all') printf '[]\n' ;;
  *) exit 92 ;;
esac
SH
  cat >"${case_dir}/bin/ss" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-lnt' ]] || exit 93
printf '%s\n' 'State Recv-Q Send-Q Local Address:Port Peer Address:Port'
SH
  chmod 0755 "${case_dir}/bin/"*
}

write_restore_sql_fixture() {
  printf '%s\n' '-- PostgreSQL database dump' '\restrict fixturetoken' 'SELECT 1;' \
    '-- PostgreSQL database dump complete' '\unrestrict fixturetoken'
}

write_trusted_restore_fixture() {
  write_restore_sql_fixture | /usr/bin/gzip -c >"$1"
  chmod 0600 "$1"
  sha256sum "$1" | cut -d ' ' -f1
}

write_update_curl_fixture() {
  mkdir -p "$1"
  cat >"$1/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == info ]]; then printf '%s\n' "${DOCKER_FIXTURE_ROOT:-$PWD}"; fi
SH
  chmod 0755 "$1/docker"
  cat >"$1/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url="${!#}"
name="${url##*/}"
if [[ -n "${CURL_FIXTURE_INTERRUPT_NAME:-}" && "$name" == "$CURL_FIXTURE_INTERRUPT_NAME" ]]; then
  printf 'partial archive'
  kill -INT "$PPID"
  sleep 5
  exit 130
fi
case "$url" in
  https://updates.invalid/latest.json|https://updates.invalid/*.sha256|https://updates.invalid/*.sig|https://updates.invalid/*.tar.gz)
    output=""
    while (($#)); do
      case "$1" in -o|--output) output="$2"; break ;; esac
      shift
    done
    if [[ -n "$output" && "$output" != - ]]; then
      cat "${CURL_FIXTURE_DIR:?}/$name" >"$output"
    else
      cat "${CURL_FIXTURE_DIR:?}/$name"
    fi ;;
  *) echo "unexpected synthetic update URL: $url" >&2; exit 22 ;;
esac
SH
  chmod 0755 "$1/curl"
}

write_update_fixture() {
  python3 - "$1" "$2" "$3" "${4:-valid}" "${5:-}" "${6:-}" \
    "${7:-### Security
- BREAKING: fixture release note}" <<'PY'
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])
current, latest = sys.argv[2:4]
mode, revision, notes_path, body = sys.argv[4:]
version = latest.removeprefix("v")
name = "chronicle-selfhost-" + version
root.mkdir(parents=True, exist_ok=True)
archive_path = root / (name + ".tar.gz")
stub = (b'#!/usr/bin/env bash\nset -euo pipefail\nprintf "HANDOFF EXECUTED\\n"\n'
        b'printf "%s\\n" "$0" "$@" > "$UPDATE_EXEC_RECORD"\n')
changelog = Path(notes_path).read_bytes() if notes_path else (
    f"# Changelog\n\n## [{version}]\n- Synthetic release notes.\n\n"
    f"## [{current}]\n- Existing release notes.\n"
).encode()
manifest = {"release_version": version}
if revision:
    manifest["source_revision"] = revision
with tarfile.open(archive_path, "w:gz") as archive:
    files = [(name + "/selfhost/chronicle", stub, 0o755), (name + "/CHANGELOG.md", changelog, 0o644)]
    if mode != "missing-manifest":
        files.append((name + "/release-manifest.json", json.dumps(manifest).encode(), 0o644))
    if mode == "traversal":
        files.append((name + "/../escaped", b"must not extract", 0o644))
    if mode == "too-many-members":
        files.extend((f"{name}/filler/{i}", b"", 0o644) for i in range(20001))
    for path, data, permissions in files:
        member = tarfile.TarInfo(path)
        member.size = len(data)
        member.mode = permissions
        archive.addfile(member, io.BytesIO(data))
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest() if mode != "corrupt" else "0" * 64
archive_path.with_suffix(".gz.sha256").write_text(f"{digest}  {archive_path.name}\n", encoding="ascii")
assets = [{"name": filename, "browser_download_url": f"https://updates.invalid/{filename}"}
          for filename in (archive_path.name, archive_path.name + ".sha256", archive_path.name + ".sha256.sig")]
(root / "latest.json").write_text(json.dumps({"tag_name": latest, "assets": assets, "body": body}))
PY
}

prepare_update_signer() {
  local run_dir="$1" installed_selfhost="$2"
  ssh-keygen -q -t ed25519 -N '' -f "$run_dir/fixture-signing-key"
  cp "$run_dir/fixture-signing-key.pub" "$installed_selfhost/release-signing.pub"
}

sign_update_fixture() {
  local run_dir="$1" version="$2" mode="${3:-valid}" checksum release_signer
  if [[ "$mode" == valid ]]; then
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT_DIR/tests/selfhost-py:$ROOT_DIR/selfhost" python3 - "$run_dir" "$version" <<'PY'
import sys
from test_release import complete_update_fixture
complete_update_fixture(sys.argv[1], sys.argv[2])
PY
  fi
  release_signer=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT_DIR/selfhost" python3 -c \
    'from chronicle_ops.release import RELEASE_SIGNER; print(RELEASE_SIGNER)')
  checksum="$run_dir/http/chronicle-selfhost-$version.tar.gz.sha256"
  rm -f -- "$checksum.sig"
  ssh-keygen -q -Y sign -n "$release_signer" -f "$run_dir/fixture-signing-key" "$checksum"
}

write_selfhost_setup_answers() {
  local password="$1" overwrite="${2:-false}" reuse_hash="${3:-false}"
  [[ "$overwrite" != true ]] || printf 'y\n'
  printf '1\nchronicle.study-host.org\n'
  # Proxy/dashboard binds plus the ten saved/default network policy prompts.
  printf '\n%.0s' {1..12}
  [[ "$reuse_hash" == true ]] || printf '%s\n%s\n' "$password" "$password"
  printf '\nn\n'
}
