# Chronicle Incident Response Runbook

Operational runbook for responding to security incidents detected by Chronicle's monitoring stack (Grafana, CrowdSec, health checks, CI workflows).

---

## Severity Levels

| Level | Classification | Examples | Response SLA | Notify |
|-------|---------------|----------|-------------|--------|
| **P0** | Critical | Data breach, honey token triggered, TDE encryption failure, unauthorized admin access | 15 minutes | Security Lead, On-Call Engineer, DBA, CTO |
| **P1** | High | CrowdSec mass blocking (>20%), AppSec unreachable, DB connection exhaustion, backup restore failure | 1 hour | On-Call Engineer, Security Lead, DBA |
| **P2** | Medium | API key usage anomaly, new CT certificate detected, DNS anomaly, elevated error rates | 4 hours | On-Call Engineer, Security Lead |
| **P3** | Low | Rate limiting triggered, single IP banned, dependency vulnerability detected | Next business day | On-Call Engineer |

---

## Escalation Path

```
On-Call Engineer
    |
    v
Security Lead (if security-relevant or P0/P1)
    |
    v
DBA (if database-related)
    |
    v
CTO (P0 only, or if data breach confirmed)
```

- P0: On-Call Engineer responds within 15 minutes, immediately pages Security Lead and DBA. CTO notified within 30 minutes.
- P1: On-Call Engineer responds within 1 hour. Security Lead notified. DBA engaged if database-related.
- P2: On-Call Engineer triages within 4 hours. Security Lead copied on findings.
- P3: On-Call Engineer reviews next business day. Filed as issue if code change needed.

---

## Initial Triage (All Severities)

1. Confirm the alert is real (check Grafana dashboard, not just the alert message).
2. Determine scope: single user, single study, or platform-wide.
3. Check if the issue is ongoing or already resolved.
4. Open an incident channel (Slack/Teams) for P0/P1 and post the initial findings.
5. Begin logging actions taken with timestamps.

---

## Alert-Specific Runbooks

### A. Honey Token Triggered (P0)

A honey token access means an attacker has reached a decoy credential or endpoint. Treat as confirmed breach until proven otherwise.

**Triage:**

1. Check Grafana dashboard for the source IP and timestamp of the trigger.
2. Identify the specific honey token that was accessed (API key, endpoint, or record).

**Containment:**

3. Ban the source IP immediately:
   ```bash
   docker exec chronicle-crowdsec cscli decisions add \
     --ip <SOURCE_IP> --type ban --duration 720h \
     --reason "honey-token-triggered"
   ```

4. Review API key access logs for the source IP:
   ```sql
   SELECT * FROM audit
   WHERE action = 'API_KEY_AUTH'
     AND ip_address = '<IP>'
   ORDER BY created_at DESC
   LIMIT 50;
   ```

5. Check for lateral movement. Query for bulk data reads from the same IP or session:
   ```sql
   SELECT action, resource_type, COUNT(*)
   FROM audit_logs
   WHERE ip_address = '<IP>'
     AND timestamp > now() - interval '24 hours'
   GROUP BY action, resource_type
   ORDER BY count DESC;
   ```

6. If lateral movement is suspected, rotate all API keys:
   ```bash
   docker exec chronicle-crowdsec cscli decisions add \
     --ip <SOURCE_IP> --type ban --duration 8760h \
     --reason "confirmed-breach-lateral-movement"
   ```

7. Check for data exfiltration (bulk reads on PHI tables):
   ```sql
   SELECT user_id, resource_type, COUNT(*), MIN(timestamp), MAX(timestamp)
   FROM audit_logs
   WHERE ip_address = '<IP>'
     AND accessed_phi = true
   GROUP BY user_id, resource_type;
   ```

**Recovery:**

8. Regenerate all honey tokens.
9. Review and tighten firewall rules if the source IP was from an unexpected range.
10. Proceed to Post-Incident process (see below).

---

### B. TDE Encryption Health Failure (P0)

TDE (Transparent Data Encryption) protects all PHI/PII at rest. A health failure means data may be unencrypted or the keyring is corrupted.

**Triage:**

1. Check the encryption health endpoint:
   ```bash
   docker exec chronicle-backend \
     curl -s http://localhost:40320/internal/health/encryption
   ```

2. Verify the keyring is intact and tables are still encrypted:
   ```bash
   docker exec chronicle-postgres \
     psql -U chronicle -c "SELECT pg_tde_is_encrypted('candidates'::regclass);"
   ```

3. Check all sensitive tables:
   ```bash
   for tbl in candidates study_participants devices sensor_data android_sensor_data \
     chronicle_usage_events chronicle_usage_stats preprocessed_usage_events \
     questionnaire_submissions time_use_diary_submissions app_usage_survey \
     upload_buffer audit audit_buffer participant_stats; do
     echo -n "$tbl: "
     docker exec chronicle-postgres \
       psql -U chronicle -t -A -c "SELECT pg_tde_is_encrypted('${tbl}'::regclass);" 2>/dev/null || echo "TABLE NOT FOUND"
   done
   ```

**Containment:**

4. **DO NOT restart PostgreSQL** until keyring status is confirmed. A restart with a missing keyring will make encrypted data permanently inaccessible.

5. If the keyring file is missing from `/var/lib/postgresql/tde-keyring/`, restore from backup immediately. See [Disaster Recovery Targets](./disaster-recovery-targets.md) for the TDE keyring recovery procedure.

6. If keys are confirmed lost and no backup exists: **RTO = UNRECOVERABLE**. Engage Security Lead and CTO immediately.

**Recovery:**

7. Once keyring is verified/restored, run the full encryption verification:
   ```bash
   ./docker/verify-encryption.sh
   ```

8. Proceed to Post-Incident process.

---

### C. CrowdSec AppSec Unreachable (P1)

CrowdSec provides WAF (Web Application Firewall) and rate limiting. When AppSec is unreachable, the system operates in fail-closed mode (all requests blocked by WAF).

**Triage:**

1. Check CrowdSec LAPI status:
   ```bash
   docker exec chronicle-crowdsec cscli lapi status
   ```

2. Check if the AppSec port is listening:
   ```bash
   docker exec chronicle-crowdsec nc -z localhost 7422
   ```

3. Check recent logs for errors:
   ```bash
   docker logs chronicle-crowdsec --tail 100
   ```

**Recovery:**

4. Restart CrowdSec:
   ```bash
   docker compose restart chronicle-crowdsec
   ```

5. Verify LAPI is back:
   ```bash
   docker exec chronicle-crowdsec cscli lapi status
   ```

6. If persistent after restart, check for configuration issues:
   ```bash
   docker exec chronicle-crowdsec cscli hub list
   docker exec chronicle-crowdsec cat /etc/crowdsec/config.yaml
   ```

7. While AppSec is down, all WAF-fronted traffic is blocked (fail-closed). Monitor backend error rates to confirm traffic resumes after recovery.

---

### D. API Key Usage Spike (P2)

An abnormal increase in API key usage may indicate a compromised key or unauthorized automation.

**Triage:**

1. Identify the key with elevated usage via Grafana API key dashboard.

2. Query for usage details:
   ```sql
   SELECT key_prefix, name, usage_count, last_used_at, scope, created_by
   FROM api_keys
   WHERE last_used_at > now() - interval '1 hour'
   ORDER BY usage_count DESC;
   ```

3. Cross-reference with audit logs:
   ```sql
   SELECT action, resource_type, ip_address, COUNT(*)
   FROM audit_logs
   WHERE additional_data->>'api_key_prefix' = '<KEY_PREFIX>'
     AND timestamp > now() - interval '1 hour'
   GROUP BY action, resource_type, ip_address
   ORDER BY count DESC;
   ```

**Response:**

4. If suspicious (unknown IP, unexpected scope of access, bulk PHI reads):
   - Revoke the key: update `api_keys` set `revoked = true` where `key_prefix = '<PREFIX>'`.
   - Notify the key owner (identified via `created_by` field).
   - Investigate what data was accessed.

5. If legitimate (known automation, expected pattern):
   - Adjust the alert threshold in Grafana to avoid future false positives.
   - Document the expected usage pattern.

---

### E. Mass IP Banning (>20% Traffic Blocked) (P1)

When CrowdSec is blocking more than 20% of incoming traffic, it may indicate either a real attack or a false-positive scenario affecting legitimate users.

**Triage:**

1. List current decisions:
   ```bash
   docker exec chronicle-crowdsec cscli decisions list
   ```

2. Check the distribution of blocked IPs (is it a single range or diverse?):
   ```bash
   docker exec chronicle-crowdsec cscli decisions list -o json | \
     jq '.[].source.ip' | sort | uniq -c | sort -rn | head 20
   ```

3. Check backend error rates in Grafana to see if legitimate traffic is being affected.

**Response (false positive):**

4. Remove specific false-positive decisions:
   ```bash
   docker exec chronicle-crowdsec cscli decisions delete --id <DECISION_ID>
   ```

5. Add the affected IP range to the allowlist if it is a known partner/institution:
   ```bash
   docker exec chronicle-crowdsec cscli decisions add \
     --ip <CIDR> --type allow --duration 720h \
     --reason "known-institution"
   ```

**Response (real attack):**

6. Verify rate limits are holding and backend is not overwhelmed.
7. Consider temporarily tightening rate limits.
8. Monitor for escalation (DDoS transitioning to targeted attack).
9. If the attack persists, engage upstream network provider for IP-level filtering.

---

### F. Backup Restore Test Failure (P1)

Weekly automated restore tests run in CI. A failure means the backup chain may be broken.

**Triage:**

1. Check the GitHub Actions workflow run for error details (which step failed: decrypt, restore, or verification).

2. Test manually on the host:
   ```bash
   ./docker/backup-chronicle.sh --verify
   ```

3. If the verification passes locally but fails in CI, the issue is environment-specific (check CI secrets, disk space).

**Response:**

4. If the encryption key is the issue:
   - Verify `/etc/chronicle/backup-encryption-key` exists and is readable.
   - Compare the key fingerprint with the one recorded during key ceremony.

5. If the backup itself is corrupted:
   - Check if the nightly backup cron is running: `crontab -l | grep backup`
   - Manually trigger a new backup: `./docker/backup-chronicle.sh --full`
   - Verify the new backup: `./docker/backup-chronicle.sh --verify`

6. Run the full encryption verification after restore:
   ```bash
   ./docker/verify-encryption.sh
   ```

---

## Post-Incident Process

All P0 and P1 incidents require a post-mortem:

1. **Within 48 hours**: Create a post-mortem document covering:
   - Timeline of events (when detected, when contained, when resolved)
   - Root cause analysis
   - Impact assessment (what data was affected, how many users)
   - Actions taken during response
   - Lessons learned
   - Action items with owners and due dates

2. **Update this runbook** with any lessons learned or new procedures discovered during the incident.

3. **File code fixes** as pull requests with the `security` label.

4. **Review alert thresholds**: If the alert was a false positive, adjust. If it was delayed, tighten.

5. **Notify affected parties** if required by HIPAA breach notification rules (within 60 days for breaches affecting 500+ individuals, without unreasonable delay for smaller breaches).

---

## Quick Reference: Key Commands

| Action | Command |
|--------|---------|
| Ban IP (CrowdSec) | `docker exec chronicle-crowdsec cscli decisions add --ip <IP> --type ban --duration 720h --reason "<reason>"` |
| Unban IP | `docker exec chronicle-crowdsec cscli decisions delete --id <ID>` |
| List bans | `docker exec chronicle-crowdsec cscli decisions list` |
| CrowdSec status | `docker exec chronicle-crowdsec cscli lapi status` |
| Encryption health | `docker exec chronicle-backend curl -s http://localhost:40320/internal/health/encryption` |
| Check table TDE | `docker exec chronicle-postgres psql -U chronicle -c "SELECT pg_tde_is_encrypted('<table>'::regclass);"` |
| Verify all encryption | `./docker/verify-encryption.sh` |
| Create backup | `./docker/backup-chronicle.sh --full` |
| Verify backup | `./docker/backup-chronicle.sh --verify` |
| Restore backup | `./docker/restore-chronicle.sh <backup-dir> [key-file]` |
| Recover TDE key | `./docker/key-recovery.sh --type tde --shares <share1> <share2> <share3>` |
