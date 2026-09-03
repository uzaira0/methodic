#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "stage-release: $*" >&2
  exit 1
}

manifest_value() {
  local manifest=$1
  local key=$2
  local count value

  count=$(grep -c "^${key}=" "$manifest" || true)
  [[ "$count" == 1 ]] || fail "$manifest must contain exactly one $key entry"
  value=$(sed -n "s/^${key}=//p" "$manifest")
  value=${value%%#*}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  [[ -n "$value" ]] || fail "$manifest has an empty $key entry"
  printf '%s\n' "$value"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

stage_release() (
  set -euo pipefail

  local source_root=$1
  local base_source=$2
  local destination=$3
  local base_manifest release_manifest base_revision release_revision
  local root_pin server_pin base_number release_number partial=""
  local key base_value release_value path expected actual
  local -a pinned_keys overlay_paths

  pinned_keys=(
    CHRONICLE_ROOT_BASE
    CHRONICLE_API
    CHRONICLE_MODELS
    CHRONICLE_SERVER
    RHIZOME
    RHIZOME_CLIENT
    BACKEND_PATCH_SHA256
    RLS_BACKGROUND_PATCH_SHA256
    SCREEN_TIME_DELTA_PATCH_SHA256
  )
  overlay_paths=(
    docker/hetzner/compose.yml
    docker/hetzner/verify-stack.sh
    docker/hetzner/source-manifest.env
  )

  [[ "$source_root" == /* && "$base_source" == /* && "$destination" == /* ]] \
    || fail "source, base, and destination paths must be absolute"
  [[ -d "$source_root" ]] || fail "release source does not exist: $source_root"
  [[ -d "$base_source" ]] || fail "base source does not exist: $base_source"
  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || fail "destination already exists: $destination"
  [[ -d "$(dirname "$destination")" ]] \
    || fail "destination parent does not exist: $(dirname "$destination")"

  release_manifest=$source_root/docker/hetzner/source-manifest.env
  base_manifest=$base_source/docker/hetzner/source-manifest.env
  [[ -f "$release_manifest" ]] || fail "release source manifest is missing"
  [[ -f "$base_manifest" ]] || fail "base source manifest is missing"

  for key in "${pinned_keys[@]}"; do
    base_value=$(manifest_value "$base_manifest" "$key")
    release_value=$(manifest_value "$release_manifest" "$key")
    [[ "$base_value" == "$release_value" ]] \
      || fail "$key changed between the base and source-only release"
  done

  root_pin=$(manifest_value "$release_manifest" CHRONICLE_ROOT_BASE)
  server_pin=$(manifest_value "$release_manifest" CHRONICLE_SERVER)
  [[ "$root_pin" =~ ^[0-9a-f]{40}$ ]] || fail "CHRONICLE_ROOT_BASE is not a full Git commit"
  [[ "$server_pin" =~ ^[0-9a-f]{40}$ ]] || fail "CHRONICLE_SERVER is not a full Git commit"
  base_revision=$(manifest_value "$base_manifest" DEPLOYMENT_REVISION)
  release_revision=$(manifest_value "$release_manifest" DEPLOYMENT_REVISION)
  [[ "$base_revision" =~ ^([0-9a-f]{7})-([0-9a-f]{7})-hzn([0-9]+)$ ]] \
    || fail "base deployment revision is malformed: $base_revision"
  base_number=${BASH_REMATCH[3]}
  [[ "$release_revision" =~ ^([0-9a-f]{7})-([0-9a-f]{7})-hzn([0-9]+)$ ]] \
    || fail "release deployment revision is malformed: $release_revision"
  release_number=${BASH_REMATCH[3]}
  [[ "$base_revision" == "${root_pin:0:7}-${server_pin:0:7}-hzn${base_number}" ]] \
    || fail "base deployment revision does not match its component pins"
  [[ "$release_revision" == "${root_pin:0:7}-${server_pin:0:7}-hzn${release_number}" ]] \
    || fail "release deployment revision does not match its component pins"
  (( release_number == base_number + 1 )) \
    || fail "release must increment exactly once from $base_revision"
  [[ "$(basename "$destination")" == "$release_revision" ]] \
    || fail "destination basename must be the unique deployment revision $release_revision"

  for path in "${overlay_paths[@]}"; do
    [[ -f "$base_source/$path" ]] || fail "base release file is missing: $path"
    [[ -f "$source_root/$path" ]] || fail "new release file is missing: $path"
  done
  for key in HETZNER_COMPOSE_SHA256 HETZNER_VERIFY_STACK_SHA256; do
    expected=$(manifest_value "$release_manifest" "$key")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "$key is not a SHA-256 value"
    case "$key" in
      HETZNER_COMPOSE_SHA256) path=docker/hetzner/compose.yml ;;
      HETZNER_VERIFY_STACK_SHA256) path=docker/hetzner/verify-stack.sh ;;
    esac
    actual=$(sha256_file "$source_root/$path")
    [[ "$actual" == "$expected" ]] || fail "$key does not match $path"
  done

  partial=$(mktemp -d "${destination}.partial.XXXXXX")
  trap '[[ -z "$partial" ]] || rm -rf -- "$partial"' EXIT
  cp -a "$base_source/." "$partial/"
  for path in "${overlay_paths[@]}"; do
    cp -p "$source_root/$path" "$partial/$path"
    cmp -s "$source_root/$path" "$partial/$path" \
      || fail "staged release does not match source file: $path"
  done
  [[ "$(manifest_value "$partial/docker/hetzner/source-manifest.env" DEPLOYMENT_REVISION)" == "$release_revision" ]] \
    || fail "staged deployment revision changed during copy"

  mv "$partial" "$destination"
  partial=""
  printf 'deployment_revision=%s\nstaged_path=%s\n' "$release_revision" "$destination"
)

main() {
  if (( $# != 2 )); then
    echo "usage: stage-release.sh BASE_SOURCE ABSOLUTE_DESTINATION" >&2
    return 64
  fi
  local script_dir source_root
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  source_root=$(cd "$script_dir/../.." && pwd)
  stage_release "$source_root" "$1" "$2"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
