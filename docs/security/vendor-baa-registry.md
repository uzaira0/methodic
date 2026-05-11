# Chronicle BAA Vendor Registry

Business Associate Agreement (BAA) tracking for all third-party services that process, store, or transmit data in the Chronicle platform. HIPAA requires a BAA with any vendor that handles PHI on behalf of a covered entity.

---

## Vendor Registry

| Vendor | Service | Data Tier | BAA Required | BAA Status | Renewal Date | Notes |
|--------|---------|-----------|-------------|------------|-------------|-------|
| Percona | PostgreSQL Distribution (self-hosted) | Tier 1-3 (local) | No (self-hosted) | N/A | N/A | No data leaves the host. Percona pg_tde extension provides TDE. Software-only relationship. |
| HashiCorp | Vault (self-hosted) | Tier 3 (key management) | No (self-hosted) | N/A | N/A | Manages TDE principal keys in production. Self-hosted; keys never leave the host. |
| CrowdSec | LAPI + AppSec (self-hosted) | N/A (processes traffic metadata, not application data) | No (self-hosted) | N/A | N/A | Online API disabled (`DISABLE_ONLINE_API=true`). No telemetry or threat intel sharing. All decisions local. |
| Google | Firebase Cloud Messaging (FCM) | Tier 2 (device tokens) | Yes | TODO | TODO | Used for push notification delivery to participant devices. Device tokens (PII) transmitted to Google. |
| Twilio | SMS / Communication | Tier 2 (phone numbers) | Yes | TODO | TODO | Used for participant notifications. Phone numbers (PII) transmitted to Twilio for SMS delivery. |
| GitHub | Actions CI/CD | Tier 4 (code only) | Recommended | TODO | TODO | No PHI in CI pipelines. Secrets managed via GitHub encrypted environment variables. Code and build artifacts only. |
| Docker Hub | Container images | N/A (no data) | No | N/A | N/A | Pull-only. No application data transmitted. Public images only. |

---

## Self-Hosted Services (No BAA Required)

The following services are self-hosted and do not transmit data to any third party. No BAA is required, but their security configuration must be maintained:

- **PostgreSQL (Percona Distribution)**: All PHI/PII stored locally with TDE. See [Data Classification](./data-classification.md) for table-level encryption requirements.
- **HashiCorp Vault**: Key management for TDE principal keys. Runs in Docker on the same host. See `docker/init-vault.sh` for configuration.
- **CrowdSec**: WAF and rate limiting. `DISABLE_ONLINE_API=true` ensures no IP or traffic data is shared with CrowdSec's cloud. See `docker/crowdsec/` for configuration.
- **Traefik**: Reverse proxy and TLS termination. Self-hosted, no external data sharing.
- **Grafana / Loki**: Monitoring and log aggregation. Self-hosted, no external data sharing.

---

## Action Items for Outstanding BAAs

Each TODO in the registry above requires resolution. Assign an owner and target date for each:

| Vendor | Action | Owner | Target Date | Status |
|--------|--------|-------|-------------|--------|
| Google (FCM) | Execute BAA for Firebase Cloud Messaging. Evaluate whether device tokens can be replaced with non-PII identifiers. | TODO | TODO | Not started |
| Twilio | Execute BAA for SMS services. Confirm Twilio's HIPAA-eligible product tier is in use. | TODO | TODO | Not started |
| GitHub | Evaluate whether a BAA is needed. Confirm no PHI enters CI pipelines (environment variables, test fixtures, logs). If confirmed clean, document the risk acceptance. | TODO | TODO | Not started |

---

## Review Schedule

- **Quarterly**: Review this registry for completeness. Verify BAA status for all vendors with TODO entries. Check for new third-party integrations that may require a BAA.
- **Annually**: Confirm renewal dates for all active BAAs. Re-evaluate self-hosted services for any changes in data flow (e.g., if CrowdSec online API is re-enabled, a BAA evaluation is required).
- **On change**: Any new third-party service integration must be added to this registry before deployment. The Security Lead must approve the data tier classification and BAA requirement determination.

---

## Criteria for BAA Requirement

A BAA is required when a vendor:

1. Receives, maintains, or transmits PHI (Tier 1) or PII linked to PHI (Tier 2) on behalf of Chronicle.
2. Has access to systems that store PHI/PII (e.g., cloud hosting providers, managed database services).
3. Provides services that involve processing PHI/PII even transiently (e.g., SMS delivery of participant-identifiable messages).

A BAA is **not** required when:

1. The service is entirely self-hosted and no data leaves the host.
2. The vendor only processes non-sensitive data (Tier 4) with no linkage to PHI/PII.
3. The vendor provides software-only (no SaaS) with no data access (e.g., open-source libraries, container images).
