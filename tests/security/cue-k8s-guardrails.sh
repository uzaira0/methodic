#!/usr/bin/env bash
set -euo pipefail

REPORT_DIR="${1:-/tmp/chronicle-cue-k8s}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

mkdir -p "$REPORT_DIR"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

command -v cue >/dev/null 2>&1 || fail "cue is required for CUE/Kubernetes profile guardrails"

(
  cd "$ROOT_DIR"
  cue export ./deploy/cue -e kubernetesProfileExport --out json > "$REPORT_DIR/kubernetes-profiles.json"
)

if command -v kubectl >/dev/null 2>&1; then
  kubectl kustomize "$ROOT_DIR/k8s/overlays/rhel9-small" > "$REPORT_DIR/rhel9-small.yaml"
elif command -v kustomize >/dev/null 2>&1; then
  kustomize build "$ROOT_DIR/k8s/overlays/rhel9-small" > "$REPORT_DIR/rhel9-small.yaml"
else
  fail "kubectl or kustomize is required to render the RHEL 9 small overlay"
fi

python3 - "$REPORT_DIR/kubernetes-profiles.json" "$REPORT_DIR/rhel9-small.yaml" <<'PY'
import json
import re
import sys

import yaml


profiles_path, rendered_path = sys.argv[1], sys.argv[2]
profiles = json.load(open(profiles_path, encoding="utf-8"))
profile = profiles["rhel9Small"]
docs = list(yaml.safe_load_all(open(rendered_path, encoding="utf-8")))

for profile_name, profile_doc in profiles.items():
    if profile_doc["backend"]["replicas"] != 1:
        raise SystemExit(
            f"{profile_name} backend replicas must remain 1 until authorization "
            "cache coherence is implemented"
        )


def find(kind, name):
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        if doc.get("kind") == kind and doc.get("metadata", {}).get("name") == name:
            return doc
    raise SystemExit(f"Rendered overlay missing {kind}/{name}")


def cpu_milli(value):
    value = str(value)
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000)


def memory_mib(value):
    value = str(value)
    match = re.fullmatch(r"([0-9]+)(Mi|Gi)", value)
    if not match:
        raise SystemExit(f"Unsupported memory quantity: {value}")
    amount = int(match.group(1))
    return amount if match.group(2) == "Mi" else amount * 1024


def container(workload, name):
    containers = workload["spec"]["template"]["spec"]["containers"]
    for item in containers:
        if item.get("name") == name:
            return item
    raise SystemExit(f"Rendered workload missing container {name}")


def env_value(container_doc, name):
    for item in container_doc.get("env", []):
        if item.get("name") == name:
            return item.get("value")
    raise SystemExit(f"Rendered container missing env {name}")


def assert_equal(label, actual, expected):
    if actual != expected:
        raise SystemExit(f"{label}: expected {expected!r}, got {actual!r}")


quota = find("ResourceQuota", "resource-quota")
quota_hard = quota["spec"]["hard"]
assert_equal("quota requests.cpu", cpu_milli(quota_hard["requests.cpu"]), profile["namespaceQuota"]["requestCpuMilli"])
assert_equal("quota requests.memory", memory_mib(quota_hard["requests.memory"]), profile["namespaceQuota"]["requestMemoryMiB"])
assert_equal("quota limits.cpu", cpu_milli(quota_hard["limits.cpu"]), profile["namespaceQuota"]["limitCpuMilli"])
assert_equal("quota limits.memory", memory_mib(quota_hard["limits.memory"]), profile["namespaceQuota"]["limitMemoryMiB"])
assert_equal("quota pods", int(quota_hard["pods"]), profile["namespaceQuota"]["pods"])

backend = find("Deployment", "chronicle-backend")
backend_container = container(backend, "backend")
assert_equal("backend replicas", backend["spec"]["replicas"], profile["backend"]["replicas"])
assert_equal("backend rollout strategy", backend["spec"]["strategy"]["type"], "Recreate")
assert_equal("backend heap", env_value(backend_container, "CHRONICLE_SERVER_XMX"), f"-Xmx{profile['backend']['heapMaxMiB'] // 1024}g")
assert_equal("backend request cpu", cpu_milli(backend_container["resources"]["requests"]["cpu"]), profile["backend"]["request"]["cpuMilli"])
assert_equal("backend request memory", memory_mib(backend_container["resources"]["requests"]["memory"]), profile["backend"]["request"]["memoryMiB"])
assert_equal("backend limit cpu", cpu_milli(backend_container["resources"]["limits"]["cpu"]), profile["backend"]["limit"]["cpuMilli"])
assert_equal("backend limit memory", memory_mib(backend_container["resources"]["limits"]["memory"]), profile["backend"]["limit"]["memoryMiB"])
assert_equal("backend export directory", env_value(backend_container, "CHRONICLE_EXPORT_DIR"), "/var/lib/chronicle/exports")
assert_equal("backend export row limit", env_value(backend_container, "CHRONICLE_EXPORT_MAX_ROWS"), "1000000")
assert_equal("backend export byte limit", env_value(backend_container, "CHRONICLE_EXPORT_MAX_BYTES"), "536870912")
assert_equal("backend export runtime limit", env_value(backend_container, "CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS"), "1800")
assert_equal("backend export aggregate limit", env_value(backend_container, "CHRONICLE_EXPORT_MAX_TOTAL_BYTES"), "8589934592")
assert_equal("backend export free-space floor", env_value(backend_container, "CHRONICLE_EXPORT_MIN_FREE_BYTES"), "1073741824")

export_mount = next(
    (
        item
        for item in backend_container.get("volumeMounts", [])
        if item.get("name") == "export-artifacts"
    ),
    None,
)
if export_mount is None:
    raise SystemExit("backend missing export-artifacts volume mount")
assert_equal("backend export mount path", export_mount.get("mountPath"), "/var/lib/chronicle/exports")
assert_equal("backend export mount writable", export_mount.get("readOnly", False), False)

export_pvc = find("PersistentVolumeClaim", "chronicle-export-artifacts")
assert_equal("backend export PVC access mode", export_pvc["spec"]["accessModes"], ["ReadWriteOnce"])
assert_equal(
    "backend export PVC storage",
    export_pvc["spec"]["resources"]["requests"]["storage"],
    "10Gi",
)

frontend = find("Deployment", "chronicle-frontend")
assert_equal("frontend replicas", frontend["spec"]["replicas"], profile["frontend"]["replicas"])

postgres = find("StatefulSet", "postgres")
postgres_container = container(postgres, "postgres")
assert_equal("postgres replicas", postgres["spec"].get("replicas", 1), 1 if profile["postgres"]["primaryOnly"] else postgres["spec"].get("replicas", 1))
assert_equal("postgres request cpu", cpu_milli(postgres_container["resources"]["requests"]["cpu"]), profile["postgres"]["request"]["cpuMilli"])
assert_equal("postgres request memory", memory_mib(postgres_container["resources"]["requests"]["memory"]), profile["postgres"]["request"]["memoryMiB"])
assert_equal("postgres limit cpu", cpu_milli(postgres_container["resources"]["limits"]["cpu"]), profile["postgres"]["limit"]["cpuMilli"])
assert_equal("postgres limit memory", memory_mib(postgres_container["resources"]["limits"]["memory"]), profile["postgres"]["limit"]["memoryMiB"])

print("CUE deployment profile matches rendered RHEL 9 small Kubernetes overlay")
PY

echo "CUE/Kubernetes guardrails complete"
