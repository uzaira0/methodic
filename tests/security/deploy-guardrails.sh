#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${1:-$ROOT_DIR/tests/security/reports}"
LEGACY_WORKFLOW="$ROOT_DIR/.github/workflows/docker-build-deploy.yml"
CD_WORKFLOW="$ROOT_DIR/.github/workflows/cd.yml"

mkdir -p "$REPORT_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

require_file_contains() {
  local file="$1"
  local pattern="$2"
  local description="$3"
  if ! grep -Eq -- "$pattern" "$file"; then
    fail "$description"
  fi
  pass "$description"
}

echo "=== Chronicle deploy guardrails ==="

if grep -Eq '^[[:space:]]*push:[[:space:]]*$' "$LEGACY_WORKFLOW"; then
  fail "Legacy self-hosted deploy workflow must not have push triggers"
fi
pass "Legacy self-hosted deploy workflow has no push trigger"

if grep -Eq 'runs-on:[[:space:]]*self-hosted' "$LEGACY_WORKFLOW"; then
  fail "Legacy self-hosted deploy workflow must not run deployment jobs on self-hosted runners"
fi
pass "Legacy self-hosted deploy workflow does not use self-hosted runners"

if grep -Eq 'docker[[:space:]]+compose[[:space:]].*-f[[:space:]]+docker-compose\.prod\.yml[[:space:]]+up[[:space:]]+-d' "$LEGACY_WORKFLOW"; then
  fail "Legacy workflow must not deploy docker-compose.prod.yml"
fi
pass "Legacy workflow does not deploy docker-compose.prod.yml"

require_file_contains "$LEGACY_WORKFLOW" \
  'Legacy self-hosted production deploy is disabled' \
  "Legacy workflow fails closed with an explicit disabled message"

require_file_contains "$CD_WORKFLOW" \
  '\./scripts/deploy\.sh[[:space:]]*\\' \
  "Current CD workflow deploys through scripts/deploy.sh"
require_file_contains "$CD_WORKFLOW" \
  'environment:[[:space:]]*$' \
  "Current CD workflow uses GitHub environments"
require_file_contains "$CD_WORKFLOW" \
  'name:[[:space:]]*production' \
  "Current CD workflow has a production environment gate"
require_file_contains "$CD_WORKFLOW" \
  "check-name:[[:space:]]*'Security Gate'" \
  "Current CD workflow waits for the Security Gate"
require_file_contains "$CD_WORKFLOW" \
  'attest-build-provenance' \
  "Current CD workflow emits GitHub provenance attestations"
require_file_contains "$CD_WORKFLOW" \
  'verify-image-provenance\.sh' \
  "Current CD workflow verifies image provenance before deploy jobs"
require_file_contains "$CD_WORKFLOW" \
  '--env-file[[:space:]]+docker/\.env\.production\.local' \
  "Current CD workflow deploys production with the untracked production env file"
require_file_contains "$CD_WORKFLOW" \
  '--env-file[[:space:]]+docker/\.env\.staging\.local' \
  "Current CD workflow deploys staging with the untracked staging env file"

require_file_contains "$ROOT_DIR/.github/workflows/security-suite.yml" \
  'prod-backend' \
  "Security suite runs on prod-backend pushes"
require_file_contains "$ROOT_DIR/.github/workflows/security-suite.yml" \
  'KUSTOMIZE_VERSION' \
  "Security suite installs kustomize for deploy guardrails"
require_file_contains "$ROOT_DIR/.github/workflows/security-suite.yml" \
  'CUE_VERSION' \
  "Security suite installs CUE for deploy guardrails"
require_file_contains "$ROOT_DIR/.github/workflows/security-suite.yml" \
  'PyYAML' \
  "Security suite installs PyYAML for schema and K8s guardrails"

if grep -Eq 'IMAGE_TAG:-latest|\$\{(BACKEND_IMAGE|FRONTEND_IMAGE):-' "$ROOT_DIR/docker/docker-compose.production.yml"; then
  fail "Production image override must not default to mutable image tags or registry paths"
fi
pass "Production image override requires explicit image references"

if python3 - "$ROOT_DIR" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
violations = []
for path in sorted((root / "docker").glob("docker-compose*.yml")):
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = re.match(r"\s*image:\s*([^#\s]+)", line)
        if not match:
            continue
        image = match.group(1)
        if image.startswith("chronicle-"):
            continue
        if re.search(r":latest(?:@|$)", image):
            violations.append(f"{path.relative_to(root)}:{line_no}: {image}")

if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
then
  pass "Docker compose overlays do not use third-party :latest images"
else
  fail "Docker compose overlays must not use third-party :latest images"
fi

if grep -Eq 'fleet-ingress|:8443:8443' "$ROOT_DIR/docker/docker-compose.traefik.yml"; then
  fail "Core Chronicle Compose must not require or expose an unrelated fleet ingress"
fi
pass "Core Chronicle Compose does not require an unrelated fleet ingress"

if python3 - "$ROOT_DIR" <<'PY'
from pathlib import Path
import sys

import yaml

root = Path(sys.argv[1])
targets = [
    ("docker/docker-compose.yml", "backend", "export_artifacts"),
    ("docker/docker-compose.dev.yml", "backend", "export_artifacts"),
    ("docker/docker-compose.prod.yml", "backend", "export_artifacts"),
    ("docker/docker-compose.traefik.yml", "chronicle-backend", "export_artifacts"),
    ("docker/hetzner/compose.yml", "backend", "/export-artifacts"),
]
expected_environment = {
    "CHRONICLE_EXPORT_DIR": "/var/lib/chronicle/exports",
    "CHRONICLE_EXPORT_MAX_ROWS": "1000000",
    "CHRONICLE_EXPORT_MAX_BYTES": "536870912",
    "CHRONICLE_EXPORT_MAX_RUNTIME_SECONDS": "1800",
    "CHRONICLE_EXPORT_MAX_TOTAL_BYTES": "8589934592",
    "CHRONICLE_EXPORT_MIN_FREE_BYTES": "1073741824",
}
for relative_path, service_name, source_fragment in targets:
    compose = yaml.safe_load((root / relative_path).read_text(encoding="utf-8"))
    service = (compose.get("services") or {}).get(service_name)
    if not isinstance(service, dict):
        raise SystemExit(f"{relative_path}: missing service {service_name}")
    environment = service.get("environment") or {}
    for name, expected in expected_environment.items():
        if str(environment.get(name)) != expected:
            raise SystemExit(f"{relative_path}: {service_name} {name} must be {expected}")
    export_mounts = [
        item
        for item in service.get("volumes", [])
        if isinstance(item, str)
        and item.endswith(":/var/lib/chronicle/exports")
    ]
    if len(export_mounts) != 1 or source_fragment not in export_mounts[0]:
        raise SystemExit(f"{relative_path}: {service_name} needs one durable export mount")

dockerfile = (root / "docker/Dockerfile.backend").read_text(encoding="utf-8")
if (
    "mkdir -p /var/log/chronicle /var/lib/chronicle/exports" not in dockerfile
    or "chown -R chronicle:chronicle /var/log/chronicle /var/lib/chronicle" not in dockerfile
):
    raise SystemExit("Backend image must pre-create the writable export volume target")

for relative_path in ("docker/docker-compose.traefik.yml", "docker/hetzner/compose.yml"):
    text = (root / relative_path).read_text(encoding="utf-8")
    if "chown" not in text or "/var/lib/chronicle/exports" not in text:
        raise SystemExit(f"{relative_path}: root bootstrap must hand export storage to chronicle")

local_path_patch = (
    root / "deploy/ansible/roles/k8s_platform/templates/local-path-config-patch.json.j2"
).read_text(encoding="utf-8")
if (
    "*chronicle-export-artifacts*)" not in local_path_patch
    or 'chmod 0700 \\"$VOL_DIR\\"' not in local_path_patch
):
    raise SystemExit("Local-path provisioner must create private export artifact directories")
PY
then
  pass "Export deployments use bounded, durable, writable artifact storage"
else
  fail "Export deployments must use bounded, durable, writable artifact storage"
fi

if grep -Eq 'contains\(steps\.meta\.outputs\.tags, '\''(latest|main)'\''\)|:[[:space:]]*\$\{\{.*(latest|main)|TAGS="\$\{PRIMARY_TAG\}"' "$CD_WORKFLOW"; then
  fail "CD workflow must not publish mutable latest/main image tags"
fi
pass "CD workflow publishes only immutable primary image tags"

if grep -Eq '^IMAGE_TAG=(latest|main|master|develop|dev|staging|production)$' "$ROOT_DIR/docker/.env.production"; then
  fail "Production env template must not set IMAGE_TAG to a mutable tag"
fi
pass "Production env template does not use a mutable IMAGE_TAG"

require_file_contains "$ROOT_DIR/tests/security/verify-image-provenance.sh" \
  'attestation verify' \
  "Image provenance verifier uses GitHub attestation verification"
require_file_contains "$ROOT_DIR/tests/security/verify-image-provenance.sh" \
  '--signer-workflow' \
  "Image provenance verifier enforces signer workflow identity"
require_file_contains "$ROOT_DIR/tests/security/verify-image-provenance.sh" \
  '--deny-self-hosted-runners' \
  "Image provenance verifier rejects self-hosted runner attestations"
require_file_contains "$ROOT_DIR/tests/security/verify-image-provenance.sh" \
  'Mutable image ref is not allowed' \
  "Image provenance verifier rejects mutable image refs"
require_file_contains "$ROOT_DIR/scripts/chronicle-rollback-smoke.sh" \
  'CHRONICLE_ROLLBACK_REQUIRE_IMAGES' \
  "Rollback smoke supports strict required-image proof"
require_file_contains "$ROOT_DIR/scripts/chronicle-rollback-smoke.sh" \
  'mutable, placeholder, untagged, or non-release ref is not acceptable' \
  "Rollback smoke rejects mutable, placeholder, or non-release expected image refs"
require_file_contains "$ROOT_DIR/scripts/chronicle-rollback-smoke.sh" \
  '\^sha-\[0-9A-Fa-f\]\{7,64\}\$' \
  "Rollback smoke accepts only hex commit-shaped sha tags"
require_file_contains "$ROOT_DIR/scripts/chronicle-rollback-smoke.sh" \
  '\^v\[0-9\]\+' \
  "Rollback smoke accepts only numbered release tags"
require_file_contains "$ROOT_DIR/scripts/chronicle-post-deploy-smoke.sh" \
  'check_body_absent' \
  "Post-deploy smoke rejects sensitive or internal public response bodies"
require_file_contains "$ROOT_DIR/scripts/chronicle-post-deploy-smoke.sh" \
  'participantId|participant_id|sourceDevice|source_device|deviceId|device_id' \
  "Post-deploy smoke rejects raw mobile identifiers in public response bodies"
require_file_contains "$ROOT_DIR/scripts/chronicle-post-deploy-smoke.sh" \
  'MOBILE_SIGNING_SECRET|PGPASSWORD' \
  "Post-deploy smoke rejects secret-name leakage in public response bodies"
require_file_contains "$ROOT_DIR/scripts/local-ci.sh" \
  'operator-secret\)[[:space:]]+job_operator_secret[[:space:]]+;;' \
  "Local CI exposes focused operator/secret evidence job"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'git -C "\$ROOT_DIR" submodule status --recursive' \
  "Release evidence records recursive submodule SHAs"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'rendered_manifest_sha256' \
  "Release evidence records rendered manifest checksum"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'kind:\[\[:space:\]\]\*Secret|\^\[\[:space:\]\]\*stringData:' \
  "Release evidence rejects plaintext Kubernetes Secrets"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'unacceptable Chronicle image ref' \
  "Release evidence rejects mutable or placeholder Chronicle image refs"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'third-party-release-images\.tsv' \
  "Release evidence records third-party image refs"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'third-party image ref is not digest-pinned' \
  "Release evidence rejects non-digest-pinned third-party image refs"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'release-deploy-rollback-matrix\.tsv' \
  "Release evidence writes release/deploy/rollback coverage matrix"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'third-party-image-refs' \
  "Release evidence matrix tracks third-party image immutability"
require_file_contains "$ROOT_DIR/scripts/chronicle-release-evidence.sh" \
  'required-live-evidence' \
  "Release evidence matrix separates static release evidence from live smoke and rollback proof"

if grep -Eq 'image\}:latest|Signing .*:latest|Verifying .*:latest|syft "\$\{?image\}?":latest|grype "\$\{?image\}?":latest|cosign .*:latest' "$ROOT_DIR/tests/security/verify-image-provenance.sh"; then
  fail "Image provenance verifier must not hard-code :latest image operations"
fi
pass "Image provenance verifier does not hard-code :latest operations"

require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/rhel9-k8s-platform.yml" \
  'chronicle_common' \
  "Ansible RHEL 9 platform playbook applies Chronicle common host hardening"
require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/rhel9-k8s-platform.yml" \
  'rke2' \
  "Ansible RHEL 9 platform playbook installs RKE2"
require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/rhel9-k8s-platform.yml" \
  'k8s_platform' \
  "Ansible RHEL 9 platform playbook installs Kubernetes platform add-ons"
require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/validate-k8s-stack.yml" \
  'chronicle_k8s_validate' \
  "Ansible validation playbook runs the Chronicle Kubernetes validation role"
require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/apply-k8s-stack.yml" \
  'chronicle_k8s_apply' \
  "Ansible apply playbook renders and dry-runs Chronicle Kubernetes overlays"
require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/apply-k8s-stack.yml" \
  'chronicle_k8s_validate' \
  "Ansible apply playbook validates the stack after overlay processing"
require_file_contains "$ROOT_DIR/deploy/ansible/playbooks/run-backup-restore-drill.yml" \
  'chronicle_backup_drill' \
  "Ansible backup drill playbook runs the Chronicle backup drill role"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_apply/tasks/main.yml" \
  'kubernetes-guardrails\.sh' \
  "Ansible apply role runs Kubernetes guardrails before overlay apply"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_apply/tasks/main.yml" \
  'dry-run=server' \
  "Ansible apply role performs server-side dry-run"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_apply/tasks/main.yml" \
  'chronicle_allow_k8s_apply' \
  "Ansible apply role requires explicit opt-in for mutating apply"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_apply/tasks/main.yml" \
  'Reject rendered plaintext Kubernetes Secrets' \
  "Ansible apply role rejects rendered plaintext Kubernetes Secrets"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_apply/tasks/main.yml" \
  'kind:.*Secret' \
  "Ansible apply role scans rendered manifests for Secret resources"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_apply/tasks/main.yml" \
  'stringData:' \
  "Ansible apply role scans rendered manifests for stringData"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'rollout status deploy/\{\{ item \}\}' \
  "Ansible validation role checks Chronicle deployment rollouts"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'wait externalsecret/\{\{ item \}\}' \
  "Ansible validation role checks Chronicle ExternalSecret readiness"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate synced Kubernetes Secret keys are populated' \
  "Ansible validation role checks synced Secret key presence without printing values"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_required_secret_contracts' \
  "Ansible production defaults declare required Kubernetes Secret contracts"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_secret_equalities' \
  "Ansible production defaults verify shared secret values match where required"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'restricted Pod Security' \
  "Ansible validation role checks restricted namespace labels"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'networkpolicy default-deny' \
  "Ansible validation role checks default-deny NetworkPolicies"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate namespace ResourceQuota and LimitRange controls' \
  "Ansible validation role checks namespace quota and limit controls"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_namespace_control_contracts' \
  "Ansible production defaults declare namespace quota and limit contracts"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'automountServiceAccountToken must be false' \
  "Ansible validation role rejects workload service-account token automount"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'mutable or untagged image' \
  "Ansible validation role rejects latest and untagged workload images"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'allowPrivilegeEscalation must be false' \
  "Ansible validation role rejects privilege escalation in workload containers"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'readOnlyRootFilesystem must be true' \
  "Ansible validation role checks read-only root filesystems"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'resources\.requests\.\{key\} is required' \
  "Ansible validation role requires workload CPU/memory requests"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'resources\.limits\.\{key\} is required' \
  "Ansible validation role requires workload CPU/memory limits"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'readinessProbe is required' \
  "Ansible validation role requires readiness probes on long-running workloads"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'livenessProbe is required' \
  "Ansible validation role requires liveness probes on long-running workloads"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'emptyDir\.sizeLimit is required' \
  "Ansible validation role requires bounded emptyDir volumes"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate active workload requests fit node capacity' \
  "Ansible validation role checks active workload capacity headroom"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate active Chronicle pods are healthy' \
  "Ansible validation role rejects active unhealthy Chronicle pods"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate Chronicle PVCs are bound to the expected storage class' \
  "Ansible validation role checks PVC binding and storage class"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate local-path backing filesystem has headroom' \
  "Ansible validation role checks local-path filesystem headroom"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_capacity_max_request_memory_percent:[[:space:]]*80' \
  "Ansible production defaults cap active memory requests below node allocatable"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_capacity_max_limit_memory_percent:[[:space:]]*150' \
  "Ansible production defaults cap active memory limit overcommit"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_local_path_max_used_percent:[[:space:]]*80' \
  "Ansible production defaults cap local-path backing filesystem usage"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_security_namespace' \
  "Ansible workload-template validation includes the security namespace"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'StatefulSet/postgres/postgres' \
  "Ansible validation documents the Postgres writable-root exception"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate workload service accounts have no Kubernetes read privileges' \
  "Ansible validation role checks workload service-account RBAC"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate disposable External Secrets reader RBAC is narrow' \
  "Ansible validation role checks External Secrets reader least privilege"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate Chronicle-owned Services are internal-only' \
  "Ansible validation role rejects public Service exposure"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate selector-backed Services have ready endpoints' \
  "Ansible validation role rejects Services without ready EndpointSlices"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Require private namespaces to remain route-free' \
  "Ansible validation role rejects routes in private namespaces"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Require public routes to match the expected edge resources' \
  "Ansible validation role checks expected public route resources"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate public routes resolve to existing Chronicle Service ports' \
  "Ansible validation role rejects public routes pointing at missing Service ports"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'chronicle/preprocessing-gui' \
  "Ansible validation role checks preprocessing GUI routing"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'strict_transport_security' \
  "Ansible validation role checks public HSTS headers"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'permissions_policy' \
  "Ansible validation role checks public Permissions-Policy headers"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'chronicle_require_crowdsec_enforced' \
  "Ansible validation role gates CrowdSec enforcement per inventory"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate public Traefik routes put CrowdSec bouncer first' \
  "Ansible validation role requires CrowdSec bouncer as the first public route middleware"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_k8s_validate/tasks/main.yml" \
  'Validate WAF blocks common malicious probes' \
  "Ansible validation role live-tests WAF blocking when enforcement is required"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_expected_waf_middleware:[[:space:]]*chronicle-crowdsec-bouncer' \
  "Ansible production defaults name the required WAF middleware"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_backup_drill/tasks/main.yml" \
  'chronicle-local-backup' \
  "Ansible backup drill role creates a backup job from the CronJob"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_backup_drill/tasks/main.yml" \
  'Chronicle Kubernetes backup verification passed:' \
  "Ansible backup drill role asserts backup verifier success"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_backup_drill/tasks/main.yml" \
  'Chronicle Kubernetes restore drill passed:' \
  "Ansible backup drill role asserts restore drill success"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_backup_drill/tasks/main.yml" \
  'extensions=2' \
  "Ansible backup drill role verifies pg_tde and pgaudit restored"
require_file_contains "$ROOT_DIR/deploy/ansible/inventory/group_vars/all.yml" \
  'chronicle_require_crowdsec_enforced:[[:space:]]*true' \
  "Ansible production defaults require CrowdSec enforcement"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_common/tasks/main.yml" \
  'ansible_facts\.distribution_major_version.*9' \
  "Ansible host hardening role is scoped to RHEL 9"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/chronicle_common/tasks/main.yml" \
  'state:[[:space:]]*enforcing' \
  "Ansible host hardening keeps SELinux enforcing"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/rke2/templates/config.yaml.j2" \
  'secrets-encryption:[[:space:]]*true' \
  "Ansible RKE2 config enables Kubernetes secrets encryption"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/rke2/templates/config.yaml.j2" \
  'profile:[[:space:]]*"\{\{ chronicle_rke2_profile \}\}"' \
  "Ansible RKE2 config uses the CIS profile variable"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/k8s_platform/tasks/main.yml" \
  'external-secrets' \
  "Ansible platform role installs External Secrets Operator"
require_file_contains "$ROOT_DIR/deploy/ansible/roles/k8s_platform/templates/local-path-config-patch.json.j2" \
  'keycloak-postgres' \
  "Ansible local-path patch preserves Keycloak Postgres PVC ownership"
require_file_contains "$ROOT_DIR/deploy/ansible/README.md" \
  'uzaira0/research-standards' \
  "Ansible README records research-standards alignment"

if grep -RInE 'AKIA[0-9A-Z]{16}|MOBILE_SIGNING_SECRET=|POSTGRES_PASSWORD=|JWT_SECRET=|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY' "$ROOT_DIR/deploy/ansible"; then
  fail "Ansible provisioning files must not contain committed credentials"
fi
pass "Ansible provisioning files do not contain obvious committed credentials"

require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'Refusing mutable or placeholder image tag' \
  "Deploy script rejects mutable or placeholder image tags"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'Refusing to deploy production with git-tracked env file' \
  "Deploy script rejects git-tracked production env files"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'docker/\.env\.production\.local' \
  "Deploy script directs production secrets to an untracked local env file"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'chmod 600' \
  "Deploy script requires private permissions on production env files"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'OIDC_ENABLED.*true' \
  "Deploy script requires OIDC for production"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'MFA enforcement cannot use the disabled upstream SAML example' \
  "Deploy script rejects the disabled SAML example until current-session MFA assurance is mapped"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED.*true' \
  "Deploy script requires explicit live MFA IdP proof attestation"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'PG_TDE_KEY_PROVIDER.*vault' \
  "Deploy script requires Vault-backed TDE for production"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'PG_TDE_VAULT_URL"[[:space:]]+"https' \
  "Deploy script requires HTTPS for production TDE Vault"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'VAULT_ENABLED.*true' \
  "Deploy script requires Vault-backed application secrets for production"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'VAULT_ADDR"[[:space:]]+"https' \
  "Deploy script requires HTTPS for production application Vault"
require_file_contains "$ROOT_DIR/scripts/deploy.sh" \
  'TESTING_LOGIN_ENABLED.*false' \
  "Deploy script forbids production testing login"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'CROWDSEC_BOUNCER_API_KEY: \$\{CROWDSEC_BOUNCER_API_KEY:\?' \
  "Traefik compose requires CrowdSec bouncer key at render time"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'refusing to start without CrowdSec WAF credentials' \
  "Traefik entrypoint refuses to start without CrowdSec WAF credentials"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'refusing to start without CrowdSec WAF middleware' \
  "Traefik entrypoint refuses to start without the CrowdSec WAF template"
require_file_contains "$ROOT_DIR/docker/traefik/dynamic/.gitignore" \
  '^crowdsec-waf\.yml$' \
  "Rendered CrowdSec WAF config is gitignored"
require_file_contains "$ROOT_DIR/docker/traefik/dynamic/crowdsec-waf.yml.template" \
  'crowdsecLapiKey: \$\{CROWDSEC_BOUNCER_API_KEY\}' \
  "CrowdSec WAF template keeps the bouncer key as a placeholder"
require_file_contains "$ROOT_DIR/docker/traefik/dynamic/crowdsec-waf.yml.template" \
  'crowdsecAppsecUnreachableBlock: true' \
  "CrowdSec WAF template blocks requests when AppSec is unreachable"

if git -C "$ROOT_DIR" ls-files --error-unmatch docker/traefik/dynamic/crowdsec-waf.yml >/dev/null 2>&1; then
  fail "Rendered CrowdSec WAF config must not be tracked"
fi
pass "Rendered CrowdSec WAF config is not tracked"

if git -C "$ROOT_DIR" check-ignore -q docker/traefik/dynamic/crowdsec-waf.yml.template; then
  fail "CrowdSec WAF template must not be ignored; clean checkouts need it to render the middleware"
fi
pass "CrowdSec WAF template is not ignored"

if awk '
  /^[[:space:]]*crowdsecLapiKey:/ && $0 !~ /\$\{CROWDSEC_BOUNCER_API_KEY\}/ { bad = 1 }
  /^[[:space:]]*crowdsecAppsecKey:/ && $0 !~ /\$\{CROWDSEC_BOUNCER_API_KEY\}/ { bad = 1 }
  END { exit(bad ? 0 : 1) }
' "$ROOT_DIR/docker/traefik/dynamic/crowdsec-waf.yml.template"; then
  fail "CrowdSec WAF template must not contain concrete LAPI/AppSec keys"
fi
pass "CrowdSec WAF template does not contain concrete keys"

require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'chronicle-body-limit\.buffering\.maxRequestBodyBytes=10485760' \
  "Traefik API body limit is capped at 10 MiB"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'chronicle-web-strip\.replacepathregex\.regex=\^/chronicle/api/web/\?\(\.\*\)' \
  "Traefik compose maps the stable browser API prefix through an explicit rewrite"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'chronicle-web-strip\.replacepathregex\.replacement=/chronicle/v3/\$\$\{1\}' \
  "Traefik compose rewrites the stable browser API to the v3 server contract"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'chronicle-web-internal-header\.headers\.customrequestheaders\.X-Chronicle-Internal-Web=\$\{CHRONICLE_INTERNAL_WEB_SECRET:\?' \
  "Traefik compose stamps the authenticated browser API boundary with a required secret"
if grep -Eq 'X-Chronicle-Internal-Web=\$\{CHRONICLE_INTERNAL_WEB_SECRET:-true\}|internal_web_value=.*:-true' \
    "$ROOT_DIR/docker/docker-compose.traefik.yml"; then
  fail "Traefik compose must not fall back to the guessable literal true for the browser API boundary"
fi
pass "Traefik compose has no guessable browser-boundary fallback"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'chronicle-web-strip,chronicle-web-internal-header,chronicle-web-ratelimit' \
  "Traefik compose applies rewrite and browser-boundary marker together"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'PathPrefix\(`/datastore/`\)' \
  "Traefik blocks the retired top-level datastore servlet alias"
require_file_contains "$ROOT_DIR/docker/nginx.prod.conf" \
  'client_max_body_size[[:space:]]+10M;' \
  "Production nginx body limit matches Traefik 10 MiB limit"
require_file_contains "$ROOT_DIR/docker/nginx.conf" \
  'client_max_body_size[[:space:]]+10M;' \
  "Base nginx body limit matches Traefik 10 MiB limit"
if grep -Eq 'client_max_body_size[[:space:]]+50M;' "$ROOT_DIR/docker/nginx.prod.conf" "$ROOT_DIR/docker/nginx.conf"; then
  fail "Production-oriented nginx configs must not allow 50 MiB request bodies"
fi
pass "Production-oriented nginx configs reject the old 50 MiB body limit"

for nginx_config in nginx.prod.conf nginx.frontend.conf; do
  require_file_contains "$ROOT_DIR/docker/${nginx_config}" \
    'set \$csp_script "script-src '\''self'\''";' \
    "${nginx_config} restricts scripts to self without inline/eval JavaScript"
  if grep -Eq "script-src[^\";]*'unsafe-(inline|eval)'" "$ROOT_DIR/docker/${nginx_config}"; then
    fail "${nginx_config} must not allow unsafe inline/eval JavaScript in CSP"
  fi
done
pass "Production frontend CSP does not allow unsafe inline/eval JavaScript"

require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^OIDC_ENABLED=true$' \
  "Production env template documents OIDC as enabled"
require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^TESTING_LOGIN_ENABLED=false$' \
  "Production env template disables testing login"
require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^ALLOW_PRODUCTION_TESTING_LOGIN=false$' \
  "Production env template disables production testing-login override"
require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^CHRONICLE_SECURITY_REQUIRE_MFA=true$' \
  "Production env template requires MFA enforcement"
require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED=false$' \
  "Production env template blocks release until live MFA IdP proof is attached"
require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^KEYCLOAK_DEFAULT_IDP=upstream-oidc$' \
  "Production env template selects the supported generic OIDC broker"
require_file_contains "$ROOT_DIR/docker/.env.production" \
  '^PG_TDE_KEY_PROVIDER=vault$' \
  "Production env template requires Vault-backed TDE"
require_file_contains "$ROOT_DIR/.gitignore" \
  'docker/\.env\.\*\.local' \
  "Root gitignore excludes local env secret files"
require_file_contains "$ROOT_DIR/docker/.gitignore" \
  '\.env\.\*\.local' \
  "Docker gitignore excludes local env secret files"

for service in postgres backend frontend nginx; do
  if ! awk -v service="$service" '
    $0 ~ "^[[:space:]]{2}" service ":[[:space:]]*$" { in_service = 1; next }
    in_service && /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/ { in_service = 0 }
    in_service && /profiles:[[:space:]]*\["legacy-standalone"\]/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$ROOT_DIR/docker/docker-compose.prod.yml"; then
    fail "Legacy docker-compose.prod.yml service '$service' must require profile legacy-standalone"
  fi
done
pass "Legacy docker-compose.prod.yml services require explicit legacy-standalone profile"
require_file_contains "$ROOT_DIR/docker/docker-compose.prod.yml" \
  'if \[ "\$\$CHRONICLE_SECURITY_REQUIRE_MFA" != "true" \]' \
  "Legacy production backend checks MFA equality at startup"
require_file_contains "$ROOT_DIR/docker/docker-compose.prod.yml" \
  'legacy production requires CHRONICLE_SECURITY_REQUIRE_MFA=true' \
  "Legacy production backend rejects MFA values other than true"
require_file_contains "$ROOT_DIR/docker/docker-compose.prod.yml" \
  'if \[ "\$\$CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED" != "true" \]' \
  "Legacy production backend checks live MFA IdP proof equality at startup"
require_file_contains "$ROOT_DIR/docker/docker-compose.prod.yml" \
  'legacy production requires verified live current-session MFA IdP proof' \
  "Legacy production backend rejects unproved MFA assurance"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'MFA enforcement cannot use the disabled upstream SAML example' \
  "Active backend rejects the disabled SAML example until current-session MFA assurance is mapped"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'production requires verified live current-session MFA IdP proof' \
  "Active production services reject release without live MFA IdP proof"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'if \[ "\$\$CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED" != "true" \]' \
  "Active production proof guard requires exact true"

if ! awk '
  /^[[:space:]]{2}chronicle-backend:[[:space:]]*$/ { in_service = 1; next }
  in_service && /^[[:space:]]{2}[A-Za-z0-9_-]+:[[:space:]]*$/ { in_service = 0 }
  in_service && /^[[:space:]]{4}read_only:[[:space:]]*true[[:space:]]*$/ { read_only = 1 }
  in_service && /\/tmp:noexec,nosuid,size=/ { tmpfs = 1 }
  in_service && /audit_logs:\/var\/log\/chronicle/ { audit = 1 }
  in_service && /mkdir -p \/tmp\/chronicle-config/ { tmp_config = 1 }
  in_service && /exec su-exec chronicle java/ { drop_privs = 1 }
  END { exit(read_only && tmpfs && audit && tmp_config && drop_privs ? 0 : 1) }
' "$ROOT_DIR/docker/docker-compose.traefik.yml"; then
  fail "Active chronicle-backend must use read-only root, tmpfs config rendering, audit log volume, and su-exec privilege drop"
fi
pass "Active chronicle-backend has constrained writable paths and drops privileges"

if python3 - "$ROOT_DIR/docker/docker-compose.traefik.yml" <<'PY'
import sys
from pathlib import Path
import yaml

compose = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
offenders = []
for name, service in sorted((compose.get("services") or {}).items()):
    networks = service.get("networks") or []
    if isinstance(networks, dict):
        network_names = set(networks)
    else:
        network_names = set(networks)
    if "traefik" in network_names and name != "traefik":
        offenders.append(name)

if offenders:
    print("Chronicle services on shared traefik-apps network: " + ", ".join(offenders))
    raise SystemExit(1)
PY
then
  pass "Only edge-traefik is attached to the shared traefik-apps network"
else
  fail "Only edge-traefik may attach to the shared traefik-apps network"
fi

require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'traefik\.docker\.network=chronicle-edge' \
  "Routed frontend and Grafana services use the Chronicle-private edge network"
require_file_contains "$ROOT_DIR/docker/docker-compose.traefik.yml" \
  'traefik\.docker\.network=chronicle-backend-bridge' \
  "Backend/API routes use the dedicated backend bridge"

if grep -Eq 'docker[[:space:]]+compose[[:space:]]+-f[[:space:]]+docker-compose\.prod\.yml[[:space:]]+up[[:space:]]+-d[[:space:]]+--build' "$ROOT_DIR/scripts/server-setup.sh"; then
  fail "server-setup.sh must not auto-deploy legacy docker-compose.prod.yml"
fi
pass "server-setup.sh does not auto-deploy legacy docker-compose.prod.yml"

if grep -Eq 'actions-runner|RUNNER_TOKEN|config\.sh --url' "$ROOT_DIR/scripts/server-setup.sh"; then
  fail "server-setup.sh must not install or request a GitHub self-hosted runner"
fi
pass "server-setup.sh does not install a GitHub self-hosted runner"
require_file_contains "$ROOT_DIR/scripts/server-setup.sh" \
  '\.env\.production\.local' \
  "server-setup.sh creates the untracked production env file"

require_file_contains "$ROOT_DIR/docker/DEPLOYMENT-MATRIX.md" \
  'legacy-standalone' \
  "Deployment matrix marks docker-compose.prod.yml as explicit legacy standalone"
require_file_contains "$ROOT_DIR/docker/DEPLOYMENT-MATRIX.md" \
  'RHEL 9 dedicated server' \
  "Deployment matrix documents the RHEL 9 dedicated-server path"
require_file_contains "$ROOT_DIR/deploy/cue/profiles.cue" \
  'k8s_rhel9_small' \
  "CUE deployment profiles model the constrained RHEL 9 small overlay"
require_file_contains "$ROOT_DIR/deploy/cue/profiles.cue" \
  'external_institutional' \
  "CUE deployment profiles externalize observability on 4-core/8GB"
require_file_contains "$ROOT_DIR/deploy/cue/chronicle_contracts.gen.cue" \
  '#DeploymentProfile' \
  "CUE deployment package consumes generated LinkML deployment enum constraints"
require_file_contains "$ROOT_DIR/tests/security/run-all-security.sh" \
  'cue-k8s-guardrails\.sh' \
  "Deploy security layer runs CUE/Kubernetes profile guardrails"
require_file_contains "$ROOT_DIR/scripts/local-ci.sh" \
  'cue-k8s\) job_cue_k8s' \
  "Local CI exposes CUE/Kubernetes profile guardrails"
require_file_contains "$ROOT_DIR/scripts/local-ci.sh" \
  'run_job cue-k8s' \
  "Local CI fast gate runs CUE/Kubernetes profile guardrails"
require_file_contains "$ROOT_DIR/tests/security/run-all-security.sh" \
  'vault-tde-guardrails\.sh' \
  "Deploy security layer runs Vault/TDE guardrails"
require_file_contains "$ROOT_DIR/ontology/chronicle.linkml.yaml" \
  'CollectionModuleId' \
  "Chronicle LinkML schema tracks collection module IDs"

if grep -Eq '^[[:space:]]{2}(prometheus|loki):[[:space:]]*$' "$ROOT_DIR/docker/docker-compose.production.yml"; then
  fail "Production override must target active VictoriaMetrics/VictoriaLogs services, not stale Prometheus/Loki names"
fi
pass "Production override does not reference stale Prometheus/Loki services"

require_file_contains "$ROOT_DIR/docker/docker-compose.production.yml" \
  '^[[:space:]]{2}victoria-metrics:[[:space:]]*$' \
  "Production override tunes active victoria-metrics service"
require_file_contains "$ROOT_DIR/docker/docker-compose.production.yml" \
  '^[[:space:]]{2}victoria-logs:[[:space:]]*$' \
  "Production override tunes active victoria-logs service"

require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  'apache/kafka:3\.9\.1@sha256:' \
  "Kafka broker image is pinned to an official Apache Kafka digest"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  'provectuslabs/kafka-ui:v0\.7\.2@sha256:' \
  "Kafka UI image is pinned to a concrete version and digest"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  '"127\.0\.0\.1:9092:9092"' \
  "Kafka overlay binds broker port to localhost"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  '"127\.0\.0\.1:8080:8080"' \
  "Kafka overlay binds Kafka UI to localhost"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  'DYNAMIC_CONFIG_ENABLED=false' \
  "Kafka UI dynamic runtime config is disabled"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  'KAFKA_CLUSTER_ID:\?' \
  "Kafka overlay requires an explicit KRaft cluster ID"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  'java\.security\.auth\.login\.config=/tmp/kafka_server_jaas\.conf' \
  "Kafka overlay generates a JAAS file for SASL inter-broker authentication"
require_file_contains "$ROOT_DIR/docker/docker-compose.kafka.yml" \
  'KAFKA_LOG_DIRS=/var/lib/kafka/data' \
  "Kafka overlay stores broker data under the official image data path"

if grep -Eq 'bitnami/kafka|/bitnami/kafka|KAFKA_CFG_' "$ROOT_DIR/docker/docker-compose.kafka.yml"; then
  fail "Kafka overlay must not use unresolved Bitnami images, Bitnami paths, or Bitnami-only env vars"
fi
pass "Kafka overlay does not depend on Bitnami-only image behavior"

if grep -Eq 'Chronicle123!|\$\{OPENSEARCH_PASSWORD:-' "$ROOT_DIR/docker/docker-compose.opensearch.yml"; then
  fail "OpenSearch overlay must not have a default admin password"
fi
pass "OpenSearch overlay requires explicit admin password"
require_file_contains "$ROOT_DIR/docker/docker-compose.opensearch.yml" \
  '"127\.0\.0\.1:9200:9200"' \
  "OpenSearch REST port is bound to localhost"
require_file_contains "$ROOT_DIR/docker/docker-compose.opensearch.yml" \
  '"127\.0\.0\.1:5601:5601"' \
  "OpenSearch Dashboards port is bound to localhost"

for compose_file in docker-compose.kafka.yml docker-compose.opensearch.yml docker-compose.loki.yml; do
  require_file_contains "$ROOT_DIR/docker/${compose_file}" \
    'no-new-privileges:true' \
    "${compose_file} sets no-new-privileges"
  require_file_contains "$ROOT_DIR/docker/${compose_file}" \
    'cap_drop:' \
    "${compose_file} drops Linux capabilities"
  require_file_contains "$ROOT_DIR/docker/${compose_file}" \
    'pids:' \
    "${compose_file} sets PID limits"
done

if grep -Eq '/var/run/docker\.sock|/var/lib/docker/containers|docker_sd_configs' \
  "$ROOT_DIR/docker/docker-compose.loki.yml" \
  "$ROOT_DIR/docker/siem/promtail-config.yml"; then
  fail "Loki/Promtail overlay must not read the Docker socket, Docker API service discovery, or all host container logs"
fi
pass "Loki/Promtail overlay scrapes only explicit Chronicle log volumes"

require_file_contains "$ROOT_DIR/docker/docker-compose.loki.yml" \
  'audit_logs:/var/log/chronicle:ro' \
  "Promtail reads Chronicle audit logs from a read-only named volume"
require_file_contains "$ROOT_DIR/docker/siem/promtail-config.yml" \
  '__path__: /var/log/chronicle/\*\.log' \
  "Promtail config tails only Chronicle audit log files"
require_file_contains "$ROOT_DIR/docker/siem/promtail-config.yml" \
  'filename: /tmp/promtail-positions\.yaml' \
  "Promtail positions file stays on tmpfs for read-only root"
require_file_contains "$ROOT_DIR/docker/siem/loki-config.yml" \
  'retention_period: 168h' \
  "Optional Loki overlay has bounded one-week retention"

if ! awk '
  /CREATE ROLE chronicle_app WITH/ { in_role = 1; next }
  in_role && /^[[:space:]]*;/ { in_role = 0 }
  in_role && /NOSUPERUSER/ { nosuper = 1 }
  in_role && /NOCREATEDB/ { nocreatedb = 1 }
  in_role && /NOCREATEROLE/ { nocreaterole = 1 }
  in_role && /BYPASSRLS/ { bypassrls = 1 }
  in_role && /CONNECTION LIMIT/ { in_role = 0 }
  END { exit(nosuper && nocreatedb && nocreaterole && !bypassrls ? 0 : 1) }
' "$ROOT_DIR/docker/init-db-roles.sql"; then
  fail "chronicle_app role must be non-superuser, non-CREATEDB, non-CREATEROLE, and unable to bypass RLS"
fi
pass "chronicle_app role is least-privilege in role bootstrap SQL"

require_file_contains "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/storage/rls/RLSRequestContext.kt" \
  'public var appRole: String\? = "chronicle_app"' \
  "Request-scoped data sources default to SET ROLE chronicle_app"
require_file_contains "$ROOT_DIR/chronicle-server/src/main/kotlin/com/openlattice/chronicle/storage/rls/RLSRequestContext.kt" \
  'stmt\.execute\("RESET ROLE"\)' \
  "Request-scoped data sources unconditionally reset role on connection close"

if grep -Eq 'superuser --|CREATEDB acknowledged|CREATEROLE acknowledged|ALTER SYSTEM access acknowledged' "$ROOT_DIR/tests/security/database-security-tests.sh"; then
  fail "Database security audit must not bless superuser request-role privileges as mitigated"
fi
pass "Database security audit does not bless superuser request-role privileges"

bash -n "$ROOT_DIR/scripts/deploy.sh"
pass "Production deploy script parses"

echo "Deploy guardrails complete. Reports directory: $REPORT_DIR"
