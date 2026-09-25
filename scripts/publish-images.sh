#!/usr/bin/env bash
# Prerequisites: authenticated gh, Docker/BuildKit with a running daemon, git, python3,
# trivy, initialized source submodules, a public root remote named public, and GHCR_TOKEN:
# a dedicated token with only write:packages (never the operator's general gh token). Run from the
# main session under CAP_MEM=12G cap: CAP_MEM=12G cap scripts/publish-images.sh <release>
set -euo pipefail

[[ $# -ge 1 && $# -le 2 && ( $# -eq 1 || ${2:-} == --dry-run ) ]] || {
  echo 'usage: scripts/publish-images.sh <release> [--dry-run]' >&2
  exit 1
}
release=$1
[[ "$release" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
  echo 'error: release must be a Docker-tag-compatible semantic version' >&2
  exit 1
}
dry_run=${2:-}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# capture assigns these variables by name, including symbolic values in dry runs.
login='' revision='' epoch='' backend_digest='' frontend_digest='' caddy_digest=''
public_repo='' notes_dir='' public_revision=''

run() {
  if [[ -n "$dry_run" ]]; then
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

capture() {
  local variable=$1
  shift
  if [[ -n "$dry_run" ]]; then
    # shellcheck disable=SC2016 # Print a command substitution without executing it.
    printf '%s=$(' "$variable"
    printf '%q ' "$@"
    printf ')\n'
    printf -v "$variable" '%s' "\${${variable}}"
  else
    local value
    value=$("$@")
    printf -v "$variable" '%s' "$value"
  fi
}

run cd "$root"
if [[ -z "$dry_run" ]]; then
  [[ -n "${GHCR_TOKEN:-}" ]] || {
    echo 'error: GHCR_TOKEN is unset; export a dedicated token with only write:packages' >&2
    exit 1
  }
  for tool in docker gh git python3 trivy; do
    command -v "$tool" >/dev/null || { echo "error: missing tool: $tool" >&2; exit 1; }
  done
  # The build tars the working tree but the release attests git rev-parse HEAD, so a dirty
  # tree or a submodule off its gitlink would ship bytes that exist in no commit.
  [[ -z $(git status --porcelain --untracked-files=no --ignore-submodules=none) ]] || {
    echo 'error: working tree is dirty; commit or clean before publishing' >&2
    exit 1
  }
  ! git submodule status --recursive | grep -qE '^[+-]' || {
    echo 'error: submodules do not match their gitlinks; sync before publishing' >&2
    exit 1
  }
  # Match the builder before any registry side effects (calendar-style 09 is invalid).
  python3 - "$release" <<'PY'
import sys
version = sys.argv[1].removeprefix("v")
core, _, pre = version.partition("-")
if (any(len(p) > 1 and p.startswith("0") for p in core.split("."))
        or (pre and any(not p or (p.isdigit() and len(p) > 1 and p.startswith("0"))
                        for p in pre.split(".")))):
    sys.exit("error: release must use semantic versioning without numeric leading zeroes")
PY
fi
capture login gh api user -q .login
if [[ -n "$dry_run" ]]; then
  # shellcheck disable=SC2016 # The dry-run login is intentionally literal.
  printf '%s\n' 'printf %s "$GHCR_TOKEN" | docker login ghcr.io --username "${login}" --password-stdin'
else
  printf %s "$GHCR_TOKEN" | docker login ghcr.io --username "$login" --password-stdin
  login=${login,,}
fi
capture revision git rev-parse HEAD
capture epoch git log -1 --format=%ct
backend="ghcr.io/$login/chronicle-backend:$release"
frontend="ghcr.io/$login/chronicle-selfhost-frontend:$release"
caddy="ghcr.io/$login/chronicle-selfhost-caddy:$release"
# Build from a tar of tracked files. The directory walk of the checkout (hundreds of MB of
# untracked build output) starves the BuildKit session healthcheck on a loaded host and
# dockerd cancels the build; the tracked tree is a few tens of MB.
build_image() { # build_image <context dir> <dockerfile in context> <tag> [docker build args...]
  local ctx=$1 dockerfile=$2 tag=$3
  shift 3
  if [[ -n "$dry_run" ]]; then
    printf '(cd %q && git ls-files --recurse-submodules -z | tar --null -T - -cf -) | ' "$ctx"
    printf '%q ' docker build -f "$dockerfile" -t "$tag" "$@" -
    printf '\n'
  else
    (cd "$ctx" && git ls-files --recurse-submodules -z | tar --null -T - -cf -) |
      docker build -f "$dockerfile" -t "$tag" "$@" -
  fi
}
build_image . docker/Dockerfile.backend "$backend" --build-arg "VCS_REF=$revision"
build_image . selfhost/Dockerfile.frontend "$frontend" --build-arg "GIT_SHA=$revision"
build_image selfhost Dockerfile.caddy "$caddy"
# Nothing reaches the registry with a fixable HIGH or CRITICAL finding.
for image in "$backend" "$frontend" "$caddy"; do
  run trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
    --ignorefile "$root/.trivyignore.yaml" "$image"
done
run docker push "$backend"
run docker push "$frontend"
run docker push "$caddy"
capture backend_digest docker inspect --format '{{index .RepoDigests 0}}' "$backend"
capture frontend_digest docker inspect --format '{{index .RepoDigests 0}}' "$frontend"
capture caddy_digest docker inspect --format '{{index .RepoDigests 0}}' "$caddy"
# The private HEAD exists in no public repository. Record and tag the curated public commit
# (scripts/publish.sh push must have run first) so the bundle maps to published source.
run git fetch public main
capture public_revision git rev-parse refs/remotes/public/main
run python3 scripts/build-selfhost-release.py --version "$release" \
  --source-revision "$revision" --public-revision "$public_revision" --source-date-epoch "$epoch" \
  --backend-image "$backend_digest" --frontend-image "$frontend_digest" --caddy-image "$caddy_digest"
capture public_repo git remote get-url public
run mkdir -p "$HOME/tmp"
capture notes_dir mktemp -d -p "$HOME/tmp" chronicle-release-notes.XXXXXX
if [[ -z "$dry_run" ]]; then
  trap 'rm -rf -- "$notes_dir"' EXIT
fi
run python3 -c '
from pathlib import Path
import re
import sys
release, destination = sys.argv[1:]
path = Path("CHANGELOG.md")
text = path.read_text() if path.is_file() else ""
sections = re.split(r"(?m)^## +", text)
note = ""
for section in sections[1:]:
    heading, _, body = section.partition("\n")
    version = heading.split()[0].strip("[]").removeprefix("v")
    if version == release.removeprefix("v"):
        note = body.strip()
        break
Path(destination).write_text((note or f"Chronicle self-host release {release}.") + "\n")
' "$release" "$notes_dir/notes.md"
bundle="build/releases/chronicle-selfhost-${release#v}.tar.gz"
run gh release create "$release" --repo "$public_repo" --target "$public_revision" \
  "$bundle" "$bundle.sha256" --notes-file "$notes_dir/notes.md"
if [[ -n "$dry_run" ]]; then
  run rm -rf -- "$notes_dir"
fi
