#!/usr/bin/env bash
# Scan every immutable image supported by the self-host release and optional overlays.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
command -v python3 >/dev/null 2>&1 || { echo 'error: python3 is required to read toolchain-manifest.yaml' >&2; exit 127; }
command -v trivy >/dev/null 2>&1 || { echo 'error: trivy is required to scan release runtime images' >&2; exit 127; }

manifest_images=$(python3 - "$root/toolchain-manifest.yaml" <<'PY'
import re
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as source:
    manifest = yaml.safe_load(source)

digest = re.compile(r"^sha256:[0-9a-f]{64}$")
images = set()
for section in ("postgres", "keycloak_postgres"):
    record = manifest.get(section)
    if not isinstance(record, dict):
        raise SystemExit(f"error: toolchain-manifest.yaml is missing {section}")
    image, pin = record.get("image"), record.get("index_digest")
    if not isinstance(image, str) or not isinstance(pin, str) or not digest.fullmatch(pin):
        raise SystemExit(f"error: {section} must declare an image and immutable index_digest")
    images.add(f"{image}@{pin}")

runtime = manifest.get("selfhost_images")
if not isinstance(runtime, dict) or not runtime:
    raise SystemExit("error: toolchain-manifest.yaml has no selfhost_images inventory")
for name, image in runtime.items():
    if not isinstance(image, str) or not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", image):
        raise SystemExit(f"error: selfhost_images.{name} must be an immutable name@sha256 reference")
    images.add(image)

for image in sorted(images):
    print(image)
PY
)
[[ -n "$manifest_images" ]] || { echo 'error: no release runtime images were found' >&2; exit 2; }

while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  printf 'Scanning release runtime image %s\n' "$image" >&2
  trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --exit-code 1 \
    --skip-db-update --skip-java-db-update --ignorefile "$root/.trivyignore.yaml" "$image"
done <<< "$manifest_images"
