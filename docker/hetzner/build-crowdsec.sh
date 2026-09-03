#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
crowdsec_commit=632274597a88a6b01ed41c0e6affca0f87ff26df
yq_commit=751d8ad57b84f1794661bc70c0afb92a22ad7b3c
image=${1:-localhost/chronicle-crowdsec:v1.7.8-hardened}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$work" init -q crowdsec
git -C "$work/crowdsec" remote add origin https://github.com/crowdsecurity/crowdsec.git
git -C "$work/crowdsec" fetch -q --depth=1 origin "$crowdsec_commit"
git -C "$work/crowdsec" checkout -q --detach FETCH_HEAD
test "$(git -C "$work/crowdsec" rev-parse HEAD)" = "$crowdsec_commit"
git -C "$work/crowdsec" apply --check "$script_dir/crowdsec/crowdsec-security.patch"
git -C "$work/crowdsec" apply "$script_dir/crowdsec/crowdsec-security.patch"

git -C "$work" init -q yq-source
git -C "$work/yq-source" remote add origin https://github.com/mikefarah/yq.git
git -C "$work/yq-source" fetch -q --depth=1 origin "$yq_commit"
git -C "$work/yq-source" checkout -q --detach FETCH_HEAD
test "$(git -C "$work/yq-source" rev-parse HEAD)" = "$yq_commit"
git -C "$work/yq-source" apply --check "$script_dir/crowdsec/yq-security.patch"
git -C "$work/yq-source" apply "$script_dir/crowdsec/yq-security.patch"

git -C "$work/crowdsec" diff --check
git -C "$work/yq-source" diff --check
podman build \
  --build-context "yq-source=$work/yq-source" \
  --tag "$image" \
  --file "$script_dir/crowdsec/Dockerfile.hardened" \
  "$work/crowdsec"

podman image inspect "$image" --format '{{.Id}}'
