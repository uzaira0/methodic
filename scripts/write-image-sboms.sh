#!/usr/bin/env bash
# Generate digest-bound SPDX release assets for the three images published by this repository.
set -euo pipefail

[[ $# -eq 5 ]] || {
  echo 'usage: scripts/write-image-sboms.sh <release> <output-dir> <backend-ref> <frontend-ref> <caddy-ref>' >&2
  exit 2
}
release=$1
output_dir=$2
shift 2
images=("$@")
[[ "$release" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
  echo 'error: release must be a Docker-tag-compatible semantic version' >&2
  exit 2
}
[[ ${#images[@]} -eq 3 ]] || { echo 'error: exactly three published image digests are required' >&2; exit 2; }
command -v syft >/dev/null 2>&1 || { echo 'error: syft is required to produce release SBOMs' >&2; exit 127; }
command -v python3 >/dev/null 2>&1 || { echo 'error: python3 is required to hash release SBOMs' >&2; exit 127; }

for image in "${images[@]}"; do
  [[ "$image" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]] || {
    echo 'error: SBOM input must be an immutable name@sha256 image reference' >&2
    exit 2
  }
done

mkdir -p -- "$output_dir"
output_dir=$(cd "$output_dir" && pwd -P)
version=${release#v}
asset_names=("chronicle-backend-${version}.spdx.json" "chronicle-frontend-${version}.spdx.json" "chronicle-caddy-${version}.spdx.json")
manifest_name="chronicle-image-sboms-${version}.json"
checksums_name="chronicle-image-sboms-${version}.sha256"
for asset in "${asset_names[@]}" "$manifest_name" "$checksums_name"; do
  [[ ! -e "$output_dir/$asset" && ! -L "$output_dir/$asset" ]] || {
    echo "error: refusing to replace existing SBOM release asset: $output_dir/$asset" >&2
    exit 2
  }
done

staging=$(mktemp -d "$output_dir/.image-sboms.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
for index in 0 1 2; do
  syft "${images[$index]}" -o spdx-json > "$staging/${asset_names[$index]}"
  [[ -s "$staging/${asset_names[$index]}" ]] || {
    echo "error: Syft produced an empty SBOM for ${images[$index]}" >&2
    exit 1
  }
done

python3 - "$release" "$staging" "$manifest_name" "$checksums_name" \
  "${asset_names[@]}" -- "${images[@]}" <<'PY'
import hashlib
import json
import pathlib
import sys

release, staging_arg, manifest_name, checksums_name = sys.argv[1:5]
staging = pathlib.Path(staging_arg)
names = sys.argv[5:8]
if sys.argv[8] != "--":
    raise SystemExit("error: invalid SBOM staging arguments")
images = sys.argv[9:12]
if len(names) != 3 or len(images) != 3:
    raise SystemExit("error: three SBOM assets and image references are required")

assets = []
for name, image in zip(names, images, strict=True):
    path = staging / name
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"error: Syft did not produce valid JSON for {image}: {error}")
    if not isinstance(document, dict) or not str(document.get("spdxVersion", "")).startswith("SPDX-"):
        raise SystemExit(f"error: Syft output for {image} is not an SPDX document")
    assets.append({
        "image": image,
        "asset": name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    })

manifest = {"schemaVersion": 1, "release": release, "sboms": assets}
manifest_path = staging / manifest_name
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
hash_targets = [*names, manifest_name]
(staging / checksums_name).write_text(
    "".join(f"{hashlib.sha256((staging / name).read_bytes()).hexdigest()}  {name}\n" for name in hash_targets),
    encoding="utf-8",
)
PY

for asset in "${asset_names[@]}" "$manifest_name" "$checksums_name"; do
  mv -- "$staging/$asset" "$output_dir/$asset"
  printf '%s\n' "$output_dir/$asset"
done
