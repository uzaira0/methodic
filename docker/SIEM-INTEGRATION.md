# Chronicle SIEM Integration Guide

Chronicle writes HIPAA-compliant audit logs in JSON format to `/var/log/chronicle/audit.log`. This guide covers integration with self-hosted log aggregation platforms.

## Audit Log Format

Each audit entry is a single JSON line (NDJSON format):

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "timestamp": "2024-01-15T14:30:00.000Z",
  "userId": "user-uuid",
  "userRole": "RESEARCHER",
  "ipAddress": "192.168.1.100",
  "userAgent": "Mozilla/5.0...",
  "action": "VIEW",
  "resourceType": "Participant",
  "resourceId": "participant-uuid",
  "studyId": "study-uuid",
  "success": true,
  "errorMessage": null,
  "accessedPHI": true,
  "phiFields": ["name", "email", "dateOfBirth"]
}
```

## Field Reference

| Field | Type | Description | HIPAA Relevance |
|-------|------|-------------|-----------------|
| `id` | UUID | Unique audit entry ID | Audit trail integrity |
| `timestamp` | ISO8601 | Event time (UTC) | When access occurred |
| `userId` | UUID | User who performed action | Who accessed data |
| `userRole` | String | User's role at time of action | Access authorization |
| `ipAddress` | String | Client IP address | Source identification |
| `userAgent` | String | Client software | Source identification |
| `action` | Enum | Action performed (see below) | What was done |
| `resourceType` | String | Type of resource accessed | What was accessed |
| `resourceId` | UUID | Specific resource ID | What was accessed |
| `studyId` | UUID | Associated study | Data scope |
| `success` | Boolean | Whether action succeeded | Outcome |
| `errorMessage` | String | Error details if failed | Failure analysis |
| `accessedPHI` | Boolean | Whether PHI was accessed | **Critical for HIPAA** |
| `phiFields` | Array | Specific PHI fields accessed | **Critical for HIPAA** |

## Action Types

| Action | Description |
|--------|-------------|
| `LOGIN` | User authenticated |
| `LOGOUT` | User logged out |
| `LOGIN_FAILED` | Failed authentication attempt |
| `VIEW` | Read/viewed data |
| `SEARCH` | Searched for data |
| `EXPORT` | Exported data |
| `DOWNLOAD` | Downloaded files |
| `CREATE` | Created new record |
| `UPDATE` | Modified existing record |
| `DELETE` | Deleted record |
| `PERMISSION_CHANGE` | Changed user permissions |
| `SETTINGS_CHANGE` | Modified system settings |
| `UNAUTHORIZED_ACCESS` | Attempted unauthorized access |
| `DATA_SUBMISSION` | Mobile app submitted data |

---

## Option 1: Grafana Loki (Recommended)

Loki is a lightweight, cost-effective log aggregation system designed to work with Grafana. It indexes only metadata, making it efficient for high-volume audit logs.

### Deploy Loki Stack

```bash
docker-compose -f docker-compose.prod.yml -f docker-compose.loki.yml up -d
```

### Architecture

```
Chronicle Backend → Promtail → Loki → Grafana
     (logs)        (shipper)  (store)  (query/dashboard)
```

### Grafana LogQL Queries

```logql
# All PHI access events
{job="chronicle-audit"} | json | accessedPHI = `true`

# Failed login attempts in last hour
{job="chronicle-audit"} | json | action = `LOGIN_FAILED`

# Unauthorized access attempts
{job="chronicle-audit"} | json | action = `UNAUTHORIZED_ACCESS`

# Data exports by user
{job="chronicle-audit"} | json | action = `EXPORT` | line_format "{{.userId}} exported from {{.studyId}}"

# PHI access rate (for alerting)
sum(rate({job="chronicle-audit"} | json | accessedPHI = `true` [5m]))
```

### Grafana Alerts

Create alerts in Grafana for:
- Failed login spike: `sum(rate({job="chronicle-audit"} | json | action="LOGIN_FAILED"[5m])) > 10`
- Unauthorized access: `count_over_time({job="chronicle-audit"} | json | action="UNAUTHORIZED_ACCESS"[1m]) > 0`
- High PHI access volume: `sum(rate({job="chronicle-audit"} | json | accessedPHI="true"[5m])) > 100`

---

## Option 2: OpenSearch (Elasticsearch Fork)

OpenSearch is the Apache 2.0 licensed fork of Elasticsearch, fully self-hostable.

### Deploy OpenSearch Stack

```bash
docker-compose -f docker-compose.prod.yml -f docker-compose.opensearch.yml up -d
```

### Architecture

```
Chronicle Backend → Fluent Bit → OpenSearch → OpenSearch Dashboards
     (logs)         (shipper)     (store)        (query/dashboard)
```

### OpenSearch Queries

```json
// All PHI access events
GET chronicle-audit-*/_search
{
  "query": {
    "term": { "accessedPHI": true }
  }
}

// Failed logins in last 24h
GET chronicle-audit-*/_search
{
  "query": {
    "bool": {
      "must": [
        { "term": { "action": "LOGIN_FAILED" } },
        { "range": { "timestamp": { "gte": "now-24h" } } }
      ]
    }
  }
}

// Aggregation: exports by user
GET chronicle-audit-*/_search
{
  "size": 0,
  "query": { "term": { "action": "EXPORT" } },
  "aggs": {
    "by_user": {
      "terms": { "field": "userId" }
    }
  }
}
```

---

## Option 3: Elasticsearch (Self-Hosted)

For teams already running Elasticsearch, Chronicle integrates directly.

### Filebeat Configuration

See `siem/filebeat.yml` for complete configuration.

### Index Template

```json
PUT _index_template/chronicle-audit
{
  "index_patterns": ["chronicle-audit-*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1
    },
    "mappings": {
      "properties": {
        "id": { "type": "keyword" },
        "timestamp": { "type": "date" },
        "userId": { "type": "keyword" },
        "userRole": { "type": "keyword" },
        "ipAddress": { "type": "ip" },
        "action": { "type": "keyword" },
        "resourceType": { "type": "keyword" },
        "resourceId": { "type": "keyword" },
        "studyId": { "type": "keyword" },
        "success": { "type": "boolean" },
        "accessedPHI": { "type": "boolean" },
        "phiFields": { "type": "keyword" }
      }
    }
  }
}
```

### Kibana Queries

```kql
# All PHI access
accessedPHI: true

# Failed logins in last 24h
action: LOGIN_FAILED AND @timestamp >= now-24h

# Unauthorized access attempts
action: UNAUTHORIZED_ACCESS

# Specific user activity
userId: "specific-user-uuid"
```

---

## Option 4: Apache Kafka

Kafka is ideal for building custom stream processing pipelines. Use it when you need real-time processing, multiple consumers, or integration with tools like Apache Flink, Spark, or custom applications.

### Architecture

```
Chronicle Backend → Fluent Bit → Kafka → [Your Consumers]
     (logs)         (shipper)   (broker)     ↓
                                         - Flink/Spark
                                         - Custom apps
                                         - Another SIEM
```

### Deploy Kafka

```bash
docker-compose -f docker-compose.prod.yml -f docker-compose.kafka.yml up -d
```

### Fluent Bit Configuration

Update `siem/fluent-bit.conf` to enable Kafka output:

```ini
[OUTPUT]
    Name              kafka
    Match             chronicle.*
    Brokers           kafka:9092
    Topics            chronicle-audit
    Timestamp_Key     timestamp
    Retry_Limit       5
    rdkafka.batch.num.messages 1000
```

### Consume with kafkacat/kcat

```bash
# Real-time tail
kcat -b kafka:9092 -t chronicle-audit -C

# With JSON formatting
kcat -b kafka:9092 -t chronicle-audit -C | jq .

# Filter PHI access only
kcat -b kafka:9092 -t chronicle-audit -C | jq 'select(.accessedPHI == true)'
```

### Kafka Connect (Sink to Other Systems)

```json
{
  "name": "chronicle-audit-sink",
  "config": {
    "connector.class": "io.confluent.connect.elasticsearch.ElasticsearchSinkConnector",
    "topics": "chronicle-audit",
    "connection.url": "http://elasticsearch:9200",
    "type.name": "_doc",
    "key.ignore": "true"
  }
}
```

---

## Docker Volume Access

The audit logs are stored in a Docker volume. To access from the host:

```bash
# Find volume location
docker volume inspect chronicle_audit_logs

# Direct path (Linux)
/var/lib/docker/volumes/chronicle_audit_logs/_data/audit.log

# Tail logs in real-time
docker-compose -f docker-compose.prod.yml exec backend tail -f /var/log/chronicle/audit.log

# Copy logs to host
docker cp chronicle-backend:/var/log/chronicle/audit.log ./audit-backup.log
```

---

## Log Rotation

Logs rotate daily and are kept for 365 days (configured in logback-spring.xml):

```
/var/log/chronicle/
├── audit.log              # Current day
├── audit.2024-01-14.log   # Previous days
├── audit.2024-01-13.log
└── ...
```

---

## HIPAA Compliance Checklist

- [ ] Audit logs capture all PHI access events
- [ ] Logs include user identity (who)
- [ ] Logs include timestamp (when)
- [ ] Logs include resource accessed (what)
- [ ] Logs include action performed (how)
- [ ] Logs include success/failure status
- [ ] PHI fields are explicitly logged when accessed
- [ ] Logs are retained for minimum 6 years (configure maxHistory)
- [ ] Logs are protected from modification (immutable storage)
- [ ] Log access itself is audited
- [ ] Alerts configured for suspicious activity
