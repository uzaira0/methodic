# Chronicle SIEM And Log Forwarding Guide

Chronicle production logging must follow the deployment's approved observability
privacy contract. This guide is for operator handoff and local rehearsal only.

Operator SIEM or institutional monitoring is preferred for production. The local
VictoriaLogs/Grafana path is a private fallback for rehearsal or an approved
exception, not a substitute for operator incident monitoring unless operator accepts that
explicitly.

## Safe Event Envelope

Forward NDJSON audit and security events using redacted references and
low-cardinality operational fields:

```json
{
  "timestamp": "2026-07-05T21:00:00Z",
  "event_type": "mobile.upload",
  "outcome": "failed",
  "route_template": "/chronicle/v4/study/{studyId}/participants/{participantId}/upload",
  "status_code": 400,
  "failure_class": "schema_mismatch",
  "correlation_id": "req_7f3b4b8d",
  "participant_ref": "participant_ref_4f9a",
  "device_ref": "device_ref_9b22",
  "server_ref": "operator_production",
  "service": "chronicle-backend"
}
```

Do not forward raw participant, device, user, study, network, token, callback,
payload, stack-trace, or mobile upload contents. Shipper configs in
`docker/siem/` defensively remove known legacy raw audit keys before forwarding.
They also stamp `redaction_contract=chronicle-production-observability-v1` and
`forbidden_fields_removed=true` so strict cutover evidence can show which
privacy contract was applied.

## Operator Handoff Requirements

Before production cutover, record:

- SIEM/log destination or operator ticket ID.
- Transport and authentication method.
- Whether raw client network identifiers are required by operator security.
- Retention owner and retention period.
- Event categories accepted by the operator.
- Sample sanitized event accepted by the operator.
- Alert routing path or documented local exception.
- Owner for failed-forwarding investigation.

The strict platform gate requires `CHRONICLE_SIEM_EVIDENCE` to point to a
readable handoff evidence file. If operator does not provide a SIEM endpoint, that
file must document the approved local fallback exception and review date.

## Minimum Forwarded Event Set

Forward at least:

- authentication and authorization failures;
- application audit events grouped into the canonical categories in the
  production observability privacy contract;
- mobile enrollment and upload failures with redacted participant/device refs;
- deploy, rollback, migration, and configuration-change events;
- backup creation, verification, restore-drill, and stale-backup events;
- Kubernetes warning events and pod restart/OOM events;
- RKE2 audit events for privileged Kubernetes API actions;
- host auditd events for SSH, sudo, identity, RKE2, and secret/config changes;
- WAF/rate-limit block events if operator exposes those events to Chronicle.

## Local Rehearsal Options

### VictoriaLogs

Use `docker/siem/victorialogs-fluent-bit.conf` for local log shipping to
VictoriaLogs. It adds Chronicle stream labels and removes legacy raw audit keys.

### Loki

Use `docker/siem/promtail-config.yml` only for local rehearsal. Keep Loki
private and short-retention.

### Kafka

Use `docker/siem/fluent-bit-kafka.conf` only when a downstream approved SIEM or
processor consumes the topic. Kafka credentials must come from the untracked
production env file or secret store. The bundled Docker Kafka stack is a local
private rehearsal overlay; do not use its plaintext listener as operator production
SIEM evidence.

### Filebeat/OpenSearch

Use `docker/siem/filebeat.yml` as a self-hosted example. It removes legacy raw
audit keys before output. Keep TLS certificate verification enabled for
production and operator handoff evidence.

## Evidence Commands

Static local evidence:

```sh
tests/security/observability-guardrails.sh /tmp/chronicle-observability-guardrails
tests/security/run-all-security.sh deploy /tmp/chronicle-security-deploy
```

Production candidate evidence:

```sh
scripts/chronicle-observability-evidence.sh \
  --siem-evidence /path/to/redacted-siem-evidence.md \
  --require-siem-evidence \
  --report-dir /path/to/private-observability-report
```

## Cutover Stop Conditions

Do not cut over if:

- SIEM evidence is missing or unreadable.
- A sample event contains forbidden raw identifiers or secrets.
- Alert routing is still the local placeholder without an approved exception.
- The log sink is public or reachable outside approved operator paths.
- Forwarding credentials are committed, pasted into chat, or printed in logs.
