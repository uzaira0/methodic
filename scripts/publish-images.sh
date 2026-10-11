#!/usr/bin/env bash
# Prerequisites: authenticated gh, Docker/BuildKit with a running daemon, git, python3,
# trivy, syft, gitleaks, rg, jq, initialized source submodules, a public root remote named public, and GHCR_TOKEN:
# a dedicated token with only write:packages (never the operator's general gh token). Run from the
# main session under CAP_MEM=12G cap: CAP_MEM=12G cap scripts/publish-images.sh <release>
set -euo pipefail

[[ $# -eq 1 || ( $# -eq 2 && ${2:-} == --dry-run ) ||
   ( $# -eq 3 && ${2:-} == --promote ) ]] || {
  echo 'usage: scripts/publish-images.sh <release> [--dry-run | --promote <smoke-result.txt>]' >&2
  exit 1
}
release=$1
[[ "$release" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
  echo 'error: release must be a Docker-tag-compatible semantic version' >&2
  exit 1
}
dry_run=${2:-}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
release_verify_key=${CHRONICLE_RELEASE_VERIFY_KEY:-$root/selfhost/release-signing.pub}
if [[ "$dry_run" == --promote ]]; then
  public_repo=$(git -C "$root" remote get-url public)
  [[ $(gh release view "$release" --repo "$public_repo" --json isDraft -q .isDraft) == true ]] || {
    echo 'error: promotion requires a draft release' >&2
    exit 1
  }
  candidate_dir=$(mktemp -d)
  trap 'rm -rf -- "$candidate_dir"' EXIT
  name="chronicle-selfhost-${release#v}.tar.gz"
  gh release download "$release" --repo "$public_repo" --dir "$candidate_dir" \
    --pattern "$name" --pattern "$name.sha256" --pattern "$name.sha256.sig"
  previous_release=$(gh release view --repo "$public_repo" --json tagName -q .tagName)
  previous_name="chronicle-selfhost-${previous_release#v}.tar.gz"
  mkdir "$candidate_dir/previous"
  gh release download "$previous_release" --repo "$public_repo" --dir "$candidate_dir/previous" \
    --pattern "$previous_name" --pattern "$previous_name.sha256" --pattern "$previous_name.sha256.sig"
  python3 - "$root" "$candidate_dir/$name" "$3" "$candidate_dir/previous/$previous_name" "$release_verify_key" "$public_repo" "$release" <<'PY_PROMOTE'
from pathlib import Path
import os
import runpy
import sys
import tarfile
root, archive, result, previous_archive, verify_key = map(Path, sys.argv[1:6])
public_repo, release = sys.argv[6:]
builder = runpy.run_path(str(root / 'scripts/build-selfhost-release.py'))
checksum = Path(str(archive) + '.sha256')
builder['verify_release_signature'](checksum, Path(str(checksum) + '.sig'), verify_key)
builder['require_archive_checksum'](archive, checksum)
previous_checksum = Path(str(previous_archive) + '.sha256')
builder['require_trusted_release_archive'](
    previous_archive, previous_checksum, Path(str(previous_checksum) + '.sig'), verify_key,
    os.environ.get(builder['PREVIOUS_RELEASE_TRUSTED_SHA256_ENV'], ''))
builder['require_smoke_result'](result, archive, previous_archive)
builder['require_public_archive_images'](archive)
with tarfile.open(archive, 'r:gz') as source:
    manifest = builder['archive_manifest'](source)
if manifest['release_version'] != release.removeprefix('v'):
    builder['fail']('candidate release version does not match the promotion tag')
builder['require_public_release_tag'](public_repo, release, manifest.get('public_revision', ''))
PY_PROMOTE
  latest=true
  [[ "$release" != *-* ]] || latest=false
  gh release edit "$release" --repo "$public_repo" --draft=false --latest="$latest"
  exit
fi
release_signing_key=${CHRONICLE_RELEASE_SIGNING_KEY:-$HOME/.config/chronicle/release-signing-key}
# capture assigns these variables by name, including symbolic values in dry runs.
login='' revision='' epoch='' backend_digest='' frontend_digest='' caddy_digest='' backup_digest=''
public_repo='' notes_dir='' public_revision='' sbom_output='' release_key_fingerprint=''

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

require_unchanged_source() {
  [[ $(git -C "$root" rev-parse HEAD) == "$revision" ]] || {
    echo 'error: source HEAD changed during publication' >&2
    return 1
  }
  local state submodules
  state=$(git -C "$root" status --porcelain --untracked-files=all --ignore-submodules=none) || return 1
  [[ -z "$state" ]] || {
    echo 'error: working tree is dirty; commit or clean before publishing' >&2
    return 1
  }
  submodules=$(git -C "$root" submodule status --recursive) || return 1
  ! rg -q '^[-+U]' <<<"$submodules" || {
    echo 'error: submodules do not match their gitlinks; sync before publishing' >&2
    return 1
  }
}

run cd "$root"
capture revision git rev-parse HEAD
if [[ -z "$dry_run" ]]; then
  [[ -n "${GHCR_TOKEN:-}" ]] || {
    echo 'error: GHCR_TOKEN is unset; export a dedicated token with only write:packages' >&2
    exit 1
  }
  [[ -f "$release_signing_key" ]] || {
    echo 'error: release signing key is missing; set CHRONICLE_RELEASE_SIGNING_KEY or install the default release-signing-key' >&2
    exit 1
  }
  [[ -f "$release_verify_key" ]] || {
    echo 'error: release verification key is missing; set CHRONICLE_RELEASE_VERIFY_KEY to the trusted public key' >&2
    exit 1
  }
  command -v ssh-keygen >/dev/null || { echo 'error: missing tool: ssh-keygen' >&2; exit 1; }
  for tool in docker gh git python3 trivy syft jq rg; do
    command -v "$tool" >/dev/null || { echo "error: missing tool: $tool" >&2; exit 1; }
  done
  # The build tars the working tree but the release attests git rev-parse HEAD, so a dirty
  # tree or a submodule off its gitlink would ship bytes that exist in no commit.
  require_unchanged_source
  # Match the builder before any registry side effects (calendar-style 09 is invalid).
  python3 - "$release" "$root/scripts/build-selfhost-release.py" <<'PY'
from pathlib import Path
import runpy
import sys
version = sys.argv[1].removeprefix("v")
core, _, pre = version.partition("-")
if (any(len(p) > 1 and p.startswith("0") for p in core.split("."))
        or (pre and any(not p or (p.isdigit() and len(p) > 1 and p.startswith("0"))
                        for p in pre.split(".")))):
    sys.exit("error: release must use semantic versioning without numeric leading zeroes")
builder = runpy.run_path(sys.argv[2])
builder["require_changelog"](Path(sys.argv[2]).resolve().parents[1] / "CHANGELOG.md", version)
PY
fi
# Verify all filtered source trees, including submodules, before registry side effects.
release_signer=$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$root/selfhost" python3 -c \
  'from chronicle_ops.release import RELEASE_SIGNER; print(RELEASE_SIGNER)')
capture public_revision bash "$root/scripts/publish.sh" verify-source
capture public_repo git remote get-url public
run python3 -c '
import runpy, sys
runpy.run_path(sys.argv[1])["require_public_release_tag"](*sys.argv[2:])
' "$root/scripts/build-selfhost-release.py" "$public_repo" "$release" "$public_revision"
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
capture epoch git log -1 --format=%ct
backend="ghcr.io/$login/chronicle-backend:$release"
frontend="ghcr.io/$login/chronicle-selfhost-frontend:$release"
caddy="ghcr.io/$login/chronicle-selfhost-caddy:$release"
backup="ghcr.io/$login/chronicle-selfhost-backup:$release"
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
  run bash "$root/scripts/scan-selfhost-release-images.sh" "$1"
}
stamp "build $caddy"
build_image . selfhost/Dockerfile.caddy "$caddy" --build-arg "SOURCE_REF=$release"
scan_image "$caddy"
stamp "build $backup"
build_image selfhost Dockerfile.backup "$backup"
scan_image "$backup"
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
run require_unchanged_source
stamp push
run docker push "$backend"
run docker push "$frontend"
run docker push "$caddy"
run docker push "$backup"
resolve_published_digest() {
  docker inspect --format '{{json .RepoDigests}}' "$1" |
    jq -er --arg repository "${1%:*}" '
      [.[] | select(startswith($repository + "@sha256:")) | select(test("@sha256:[0-9a-f]{64}$"))]
      | if length == 1 then .[0] else error("missing or ambiguous published repository digest") end'
}
capture backend_digest resolve_published_digest "$backend"
capture frontend_digest resolve_published_digest "$frontend"
capture caddy_digest resolve_published_digest "$caddy"
capture backup_digest resolve_published_digest "$backup"
# The private HEAD exists in no public repository. Record and tag the curated public commit
# verified above so the bundle maps to published source.
stamp 'bundle and GitHub release'
bundle="build/releases/chronicle-selfhost-${release#v}.tar.gz"
if [[ -z "$dry_run" && ( -e "$bundle.sha256.sig" || -L "$bundle.sha256.sig" ) ]]; then
  echo 'error: refusing to replace an existing release signature' >&2
  exit 1
fi
run python3 scripts/build-selfhost-release.py --version "$release" \
  --source-revision "$revision" --public-revision "$public_revision" --source-date-epoch "$epoch" \
  --backend-image "$backend_digest" --frontend-image "$frontend_digest" --caddy-image "$caddy_digest" \
  --backup-image "$backup_digest"
run ssh-keygen -Y sign -n "$release_signer" -f "$release_signing_key" "$bundle.sha256"
run python3 -c '
from pathlib import Path
import runpy
import sys
root, checksum, verify_key = map(Path, sys.argv[1:])
runpy.run_path(str(root / "scripts/build-selfhost-release.py"))["verify_release_signature"](
    checksum, Path(str(checksum) + ".sig"), verify_key)
' "$root" "$bundle.sha256" "$release_verify_key"
capture sbom_output bash "$root/scripts/write-image-sboms.sh" "$release" "$root/build/releases" \
  "$backend_digest" "$frontend_digest" "$caddy_digest" "$backup_digest"
mapfile -t sbom_assets <<< "$sbom_output"
run mkdir -p "$HOME/tmp"
capture notes_dir mktemp -d -p "$HOME/tmp" chronicle-release-notes.XXXXXX
if [[ -z "$dry_run" ]]; then
  trap 'rm -rf -- "$notes_dir"' EXIT
fi
# Operators land on this page, and `./chronicle update --check` prints it: lead with the steps.
capture release_key_fingerprint ssh-keygen -lf "$release_verify_key" -E sha256
# shellcheck disable=SC2016 # Python writes literal shell commands into the release notes.
run python3 -c '
from pathlib import Path
import sys
release, destination, fingerprint, signer = sys.argv[1:]
v = release.removeprefix("v")
Path(destination).write_text(f"""## New installation

Download `chronicle-selfhost-{v}.tar.gz`, its `.sha256` and `.sha256.sig` sidecars. Obtain the
release public key independently from your institution handoff, save it as `release-signing.pub`,
and compare its fingerprint with the handoff before installation. This release expects:
`{fingerprint}`. On the Linux server, as a user in the `docker` group:

```bash
set -e
# 1. Compare this fingerprint with the independently trusted institution handoff
ssh-keygen -lf release-signing.pub -E sha256
printf "{signer} %s\\n" "$(cat release-signing.pub)" > allowed_signers
ssh-keygen -Y verify -f allowed_signers -I {signer} -n {signer} \\
  -s chronicle-selfhost-{v}.tar.gz.sha256.sig < chronicle-selfhost-{v}.tar.gz.sha256
# 2. Check the download and unpack it (nothing is built; images are pulled later)
sha256sum -c chronicle-selfhost-{v}.tar.gz.sha256
tar -xzpf chronicle-selfhost-{v}.tar.gz
cd chronicle-selfhost-{v}/selfhost

# 3. Answer the setup questions (domain, TLS mode, dashboard password; secrets are generated)
./chronicle setup

# 4. Check the host, pull the images and start
./chronicle up

# 5. Confirm the server is exposed as intended, then check backups and health
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
' "$release" "$notes_dir/notes.md" "$release_key_fingerprint" "$release_signer"
# Keep candidates out of the update channel until the downloaded artifact has been drilled.
release_flags=(--draft --latest=false)
[[ "$release" != *-* ]] || release_flags+=(--prerelease)
run gh release create "$release" --repo "$public_repo" --target "$public_revision" \
  "$bundle" "$bundle.sha256" "$bundle.sha256.sig" "${sbom_assets[@]}" --notes-file "$notes_dir/notes.md" "${release_flags[@]}"
if [[ -n "$dry_run" ]]; then
  run rm -rf -- "$notes_dir"
fi
stamp 'done'
