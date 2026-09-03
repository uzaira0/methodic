# Chronicle Ansible Provisioning

This is the primary operator path for RHEL 9 Kubernetes host setup. The raw
commands in the runbooks are retained for diagnosis and break-glass recovery,
but routine setup should run through Ansible so host state is repeatable.

The playbooks intentionally do not create AWS resources, create IAM objects,
print secrets, or apply Chronicle app manifests. They prepare the host and
platform primitives needed by the Kubernetes overlays:

- RHEL 9 prerequisite packages, chrony, SELinux enforcing, firewalld policy
- optional managed swap file with conservative swappiness
- persistent bounded journald storage
- SSH daemon hardening, optional user allowlisting, and login banners
- shell/account defaults, cron/at allowlists, `/dev/shm` hardening, and unused
  filesystem/USB module blacklisting
- custom authselect-managed PAM faillock, password quality, password history,
  null-password rejection, and optional `su` restriction through an empty
  scanner-selected group
- legacy network package removal and legacy service disable/mask enforcement
- identity file and bootloader config permission enforcement
- journald sealing and auditd hostname tagging
- auditd rules for identity, sudo, SSH, RKE2, systemd, sysctl, audit config,
  privileged-command execution, and UID/GID-changing syscalls
- AIDE baseline database initialization plus a daily AIDE timer and optional
  OpenSCAP-compatible cron wrapper
- dnf-automatic security update downloads without auto-apply by default
- kernel hardening sysctls
- RKE2 with CIS profile, secrets encryption, Cilium, and Traefik
- Kubernetes API audit logging and local RKE2 etcd snapshots
- Helm
- External Secrets Operator
- local-path storage and Chronicle PVC permission setup
- AWS Nitro Enclaves hello-world lab tooling for the disposable AWS rehearsal
  host, with allocator cleanup after each run

Install collections:

```bash
cd /Users/<user>/chronicle/methodic/deploy/ansible
ansible-galaxy collection install -r requirements.yml
```

If `ansible-playbook` is not installed globally on the Mac, use `uvx`:

```bash
cd /Users/<user>/chronicle/methodic/deploy/ansible
uvx --from ansible-core ansible-galaxy collection install -r requirements.yml
uvx --from ansible-core ansible-playbook playbooks/validate-rhel9-platform.yml
```

Inventory selection:

- `inventory/operator.example.ini` is the committed deployment template. Copy it
  to an untracked inventory before inserting real hostnames, IPs, usernames,
  key paths, or ticket-specific values.
- Strict portable evidence rejects tracked, symlinked, or group/world-accessible
  inventories. Use a real untracked local inventory for
  `CHRONICLE_ANSIBLE_INVENTORY`, set it to mode `0600`, and do not point it at
  the committed examples or a symlink.
- The example host-variable files show the expected production and restore
  variables without secrets.

The default `ansible.cfg` points at ignored `inventory/local.ini`. Copy an
example there or pass an untracked inventory explicitly:

```bash
ansible-playbook -i inventory/production.local.ini playbooks/validate-rhel9-platform.yml
```

Dry-run the selected host:

```bash
ansible-playbook playbooks/rhel9-k8s-platform.yml --check --diff
```

Apply:

```bash
ansible-playbook playbooks/rhel9-k8s-platform.yml
```

Render and server-side dry-run the Chronicle Kubernetes overlays:

```bash
ansible-playbook playbooks/apply-k8s-stack.yml
```

Actually apply the configured overlays only when you intend to mutate the
target cluster:

```bash
ansible-playbook playbooks/apply-k8s-stack.yml -e chronicle_allow_k8s_apply=true
```

The default is dry-run only. The playbook runs the Kubernetes guardrails first,
renders each configured overlay into `/tmp/chronicle-k8s-rendered`, rejects
rendered plaintext Secrets, performs `kubectl apply --dry-run=server`, and then
runs the stack validation role. Production inventories should override
`chronicle_k8s_overlays` to the exact release overlays they intend to apply.
The shared default is an empty overlay list so no environment is implied by
`group_vars/all.yml`.

Validate the already-applied Kubernetes stack:

```bash
ansible-playbook playbooks/validate-k8s-stack.yml
```

The validation playbook is read-only. It checks node readiness, Chronicle
single-node Cilium operator convergence, absence of active pods stuck outside
Running/Succeeded, deployments/statefulsets, constrained zero-surge rollout
strategy where configured, ExternalSecrets, synced Secret key presence and
minimum lengths without printing values, internal TLS secret expiry/chain/keypair
validation without printing certificate or key material, sensitive env vars using
Secret references instead of literals, ConfigMaps without sensitive-looking key
names, no workload `envFrom` bulk imports, restricted namespace labels,
default-deny NetworkPolicies, absence of disallowed `NodePort`, `LoadBalancer`, and
`ExternalName` Services, absence of Service external address fields, namespace
ResourceQuota/LimitRange controls, workload template and named ServiceAccount
token automount settings, named ServiceAccounts without attached Secret references, absence of managed workload
`hostNetwork`/`hostPort` usage and workload DNS overrides, workload image mutability, restricted container
security contexts, mounted Secret volume file modes, workload CPU/memory requests and limits,
readiness/liveness probes on long-running containers, bounded
`emptyDir` volumes, active workload request headroom against node allocatable
capacity, active pod health, absence of unresolved warning events in the
configured recent lookback window after the configured post-reboot and
post-remediation checks, participant-status values against the server enum
contract, bound PVCs on the expected storage class, local-path filesystem
headroom, private observability, workload and secret-reader RBAC, RBAC binding
and Role allowlists, default-deny NetworkPolicy semantics, NetworkPolicy object
allowlists, public Gateway API route contracts, suspended backup CronJobs,
stable workload image pull policies, explicit denial of host PID/IPC sharing,
default service accounts, privileged containers, and unmasked proc mounts, backup
CronJob safety contracts, internal-only Service exposure, ready endpoints for
selector-backed Services, public routes resolving to existing Chronicle Service
ports, private namespace route isolation, expected public route resources,
HTTPS-only public Traefik IngressRoute structure, exact-host public Traefik route
matches, public Traefik security-header and rate-limit middleware structure,
required rate-limit middleware attachment on public route classes, public route
priority/order invariants, local backup artifact permissions and encrypted-only
contents, local backup manifest checksums, encrypted artifact hashes, latest
backup freshness, public route behavior, APK/preprocessing routes, public edge
security headers, and the WAF enforcement gate. The primary Postgres container is the only current
read-write-root
exception because its runtime paths are not yet fully separated into writable
mounts. A rehearsal inventory may set `chronicle_require_crowdsec_enforced: false`
only when its ingress controller cannot enforce CrowdSec; production inventories
should leave the default `true`.

When `chronicle_require_crowdsec_enforced` is true, validation requires all of:
CrowdSec rollout healthy, Traefik configured with the bouncer plugin and
`abortOnPluginFailure=true`, every Traefik public route has
`chronicle_expected_waf_middleware` as its first middleware, a benign `/health`
request succeeds, and common SQLi/XSS probes return `403`.

Validate the RHEL/RKE2 platform baseline:

```bash
ansible-playbook playbooks/validate-rhel9-platform.yml
```

This validation playbook is read-only. It checks RHEL 9, SELinux enforcing,
chronyd, optional swap file state and swappiness, reboot-required state, host
TCP/UDP listener allowlists, host resource pressure thresholds, public
certificate expiry, host filesystem privilege drift on the root filesystem
(unexpected setuid/setgid files, unowned files, and non-sticky world-writable
directories), RKE2, the expected firewalld posture, dnf-automatic timer state,
dnf-automatic security-download policy, auditd state, SSH hardening, SSH
authorized key file ownership/modes, managed kernel sysctls, login banners,
`/dev/shm` mount flags, shell/account defaults, authselect/PAM policy, auditd retention,
OpenSCAP packages, disabled module policy, identity and bootloader file
permissions, legacy package/service absence, journald hardening,
audit/logrotate/AIDE baseline files, privileged-command and identity-change
audit coverage, the AIDE timer and OpenSCAP cron wrapper when enabled, cron/at
hardening, RKE2 audit policy and snapshot paths, RKE2 config and kubeconfig
permissions, local storage ownership/mode/SELinux label, hardened RKE2 config
values, Chronicle node labels, and Kubernetes API readiness. Reboot-required validation is
non-strict by default so a patched host can remain online until a deliberate
maintenance reboot; set `chronicle_reboot_required_strict=true` when enforcing
post-reboot evidence. Host listener validation is strict for public and
private-bind ports, but allows explicitly named dynamic loopback listeners such
as `cilium-agent` high ports because those can change across boots without
expanding network exposure.

Run the disposable AWS Nitro Enclaves lab:

```bash
ansible-playbook playbooks/run-nitro-enclave-lab.yml
```

This playbook is for temporary AWS capability rehearsal, not for standing app
runtime. It verifies the Nitro kernel devices, installs the pinned AWS Nitro CLI
tooling without replacing the RHEL in-kernel driver, builds and runs the AWS
hello-world enclave, captures evidence under
`/var/log/chronicle/evidence/nitro-enclaves/runs/`, then terminates the enclave,
stops/disables the allocator, resets the Nitro CPU pool, and clears 2 MiB
hugepage allocation.

Run an AIDE evidence check:

```bash
ansible-playbook playbooks/run-aide-check.yml
```

On constrained hosts, this playbook refuses by default. An 8 vCPU / 16 GiB host
passes the default memory guard. For smaller 4 vCPU / 8 GiB rehearsal hosts, run it only during a quiet
maintenance window with an explicit override:

```bash
ansible-playbook playbooks/run-aide-check.yml \
  -e chronicle_aide_allow_constrained_host=true
```

Evidence logs are written under `/var/log/chronicle/evidence`. A clean AIDE
result exits successfully; detected file differences are reported and fail the
playbook so the evidence cannot be missed.

After reviewing expected maintenance drift, refresh the AIDE baseline through
the explicit mutating playbook. This backs up the old database, activates the
new one, and immediately proves a clean post-refresh check:

```bash
ansible-playbook playbooks/refresh-aide-baseline.yml \
  -e chronicle_aide_refresh_baseline=true
```

OpenSCAP evidence scan:

```bash
ansible-playbook playbooks/run-rhel9-openscap-scan.yml
```

OpenSCAP is the host compliance scanner for SCAP/XCCDF/OVAL content, currently
the RHEL 9 CIS Server Level 1 profile. It is separate from OWASP work:
OWASP Dependency-Check and the NVD API key cover dependency CVE scanning, while
OpenSCAP covers operating-system configuration. Treat OpenSCAP failures as
decision inputs, not automatic remediation approval; controls that alter
authentication, SSH access, disk layout, crypto policy, or Kubernetes networking
need a maintenance window and rollback plan.

Keep live host account names, authselect choices, exception decisions, and exact
OpenSCAP scores in private operator evidence rather than this reusable tree. Treat
authentication-adjacent remediation such as `AllowUsers`, PAM group restrictions,
and authselect changes as maintenance-window work with a tested rollback path.

On 4 vCPU / 8 GiB nodes, the full CIS Server Level 1 scan caused heavy memory
pressure when run beside the full app and observability stack. Smaller rehearsal hosts should use a maintenance window, pause
observability first, or pass an explicit constrained-host override:

```bash
ansible-playbook playbooks/run-rhel9-openscap-scan.yml \
  -e chronicle_openscap_allow_constrained_host=true \
  -e chronicle_openscap_timeout_seconds=900
```

Run the backup, verifier, and restore drill evidence sequence:

```bash
ansible-playbook playbooks/run-backup-restore-drill.yml
```

This playbook validates the stack first, creates one-off Jobs from the suspended
backup CronJobs, waits for completion, captures logs, and asserts the success
markers from the backup verifier and restore drill. Successful drill Jobs are
kept by default as operational evidence; set
`chronicle_delete_successful_drill_jobs=true` only for disposable cleanup.

Set `chronicle_backup_drill_pause_observability: true` only on constrained
rehearsal hosts; the role pauses private observability deployments during the
drill and restores them in an `always` block. Production inventories should
keep the default `false` and size the node so backup jobs schedule without
pausing monitoring.

For RHEL 9, start from `inventory/operator.example.ini`. Keep secrets outside inventory. Do not put Vault/OpenBao
tokens, database passwords, mobile signing secrets, kubeconfigs, private SSH key
material, operator ticket exports, or cloud credentials in Ansible variables committed to git.

Standards alignment:

- security and supply-chain gates follow the detector-backed style in
  `uzaira0/research-standards/registry/standards.yaml`
- deployment profiles and enum names remain LinkML/CUE-owned in
  `ontology/chronicle.linkml.yaml` and `deploy/cue/`
- Ansible owns host convergence, not domain contracts or application secrets
