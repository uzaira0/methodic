#!/usr/bin/env bash
# Prerequisites: authenticated gh, Docker/BuildKit with a running daemon, git, python3,
# trivy, syft, initialized source submodules, a public root remote named public, and GHCR_TOKEN:
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

# Phase timestamps on stderr: the 2026.9.25 run lost ~45 min that no log could place.
stamp() { printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }

run cd "$root"
if [[ -z "$dry_run" ]]; then
  [[ -n "${GHCR_TOKEN:-}" ]] || {
    echo 'error: GHCR_TOKEN is unset; export a dedicated token with only write:packages' >&2
    exit 1
  }
  for tool in docker gh git python3 trivy syft; do
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
# Fetch the vulnerability DBs first so a slow or failed download shows up before any build.
stamp 'trivy db download'
run trivy image --quiet --download-db-only
run trivy image --quiet --download-java-db-only
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
# Nothing reaches the registry with a fixable HIGH or CRITICAL finding. Each image is scanned
# right after its build, smallest first, so a finding fails the run before the next build.
scan_image() {
  stamp "scan $1"
  run trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --exit-code 1 \
    --skip-db-update --skip-java-db-update --ignorefile "$root/.trivyignore.yaml" "$1"
}
stamp "build $caddy"
build_image . selfhost/Dockerfile.caddy "$caddy" --build-arg "SOURCE_REF=$release"
scan_image "$caddy"
stamp "build $frontend"
build_image . selfhost/Dockerfile.frontend "$frontend" \
  --build-arg "GIT_SHA=$revision" --build-arg "SOURCE_REF=$release"
scan_image "$frontend"
stamp "build $backend"
build_image . docker/Dockerfile.backend "$backend" \
  --build-arg "VCS_REF=$revision" --build-arg "SOURCE_REF=$release"
scan_image "$backend"
stamp 'scan release runtime dependencies'
run bash "$root/scripts/scan-selfhost-release-images.sh"
stamp push
run docker push "$backend"
run docker push "$frontend"
run docker push "$caddy"
capture backend_digest docker inspect --format '{{index .RepoDigests 0}}' "$backend"
capture frontend_digest docker inspect --format '{{index .RepoDigests 0}}' "$frontend"
capture caddy_digest docker inspect --format '{{index .RepoDigests 0}}' "$caddy"
# The private HEAD exists in no public repository. Record and tag the curated public commit
# (scripts/publish.sh push must have run first) so the bundle maps to published source.
stamp 'bundle and GitHub release'
run git fetch public main
capture public_revision git rev-parse refs/remotes/public/main
run python3 scripts/build-selfhost-release.py --version "$release" \
  --source-revision "$revision" --public-revision "$public_revision" --source-date-epoch "$epoch" \
  --backend-image "$backend_digest" --frontend-image "$frontend_digest" --caddy-image "$caddy_digest"
run bash "$root/scripts/write-image-sboms.sh" "$release" "$root/build/releases" \
  "$backend_digest" "$frontend_digest" "$caddy_digest"
sbom_version=${release#v}
sbom_assets=(
  "$root/build/releases/chronicle-backend-${sbom_version}.spdx.json"
  "$root/build/releases/chronicle-frontend-${sbom_version}.spdx.json"
  "$root/build/releases/chronicle-caddy-${sbom_version}.spdx.json"
  "$root/build/releases/chronicle-image-sboms-${sbom_version}.json"
  "$root/build/releases/chronicle-image-sboms-${sbom_version}.sha256"
)
capture public_repo git remote get-url public
run mkdir -p "$HOME/tmp"
capture notes_dir mktemp -d -p "$HOME/tmp" chronicle-release-notes.XXXXXX
if [[ -z "$dry_run" ]]; then
  trap 'rm -rf -- "$notes_dir"' EXIT
fi
# Operators land on this page, and `./chronicle update --check` prints it: lead with the steps.
run python3 -c '
from pathlib import Path
import sys
release, destination = sys.argv[1:]
v = release.removeprefix("v")
Path(destination).write_text(f"""## New installation

Download `chronicle-selfhost-{v}.tar.gz` and `chronicle-selfhost-{v}.tar.gz.sha256`, then on the
Linux server, as a user in the `docker` group:

```bash
# 1. Check the download and unpack it (nothing is built; images are pulled later)
sha256sum -c chronicle-selfhost-{v}.tar.gz.sha256
tar -xzpf chronicle-selfhost-{v}.tar.gz
cd chronicle-selfhost-{v}/selfhost

# 2. Answer the setup questions (domain, TLS mode, dashboard password; secrets are generated)
./chronicle setup

# 3. Check the host, pull the images and start
./chronicle up

# 4. Confirm the server is exposed as intended, then check backups and health
./chronicle verify
./chronicle doctor
```

The dashboard is on the private listener, e.g. `https://127.0.0.1:8081/chronicle` over an SSH
tunnel. The public domain serves only the phones. Full guide: `selfhost/README.md` in the bundle,
section "Quick start".

To replace an existing installation and discard its data, first follow
`selfhost/docs/UNINSTALL-DATA-DELETION.md`, section "Remove the application and all installation
storage".

## Updating an existing installation

From the current installation'"'"'s `selfhost/` directory:

```bash
./chronicle update
```

It downloads this release, verifies it, takes a verified backup, and upgrades in place.

## What changed

See `CHANGELOG.md` in the bundle, section [{v}].
""")
' "$release" "$notes_dir/notes.md"
bundle="build/releases/chronicle-selfhost-${release#v}.tar.gz"
run gh release create "$release" --repo "$public_repo" --target "$public_revision" \
  "$bundle" "$bundle.sha256" "${sbom_assets[@]}" --notes-file "$notes_dir/notes.md"
if [[ -n "$dry_run" ]]; then
  run rm -rf -- "$notes_dir"
fi
stamp 'done'
