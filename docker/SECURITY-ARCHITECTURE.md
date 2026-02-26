# Enterprise Security Architecture Guide

This document outlines the defense-in-depth security architecture for Chronicle, a HIPAA/GDPR compliant research data collection platform requiring 99% uptime.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Layer 0: External/Internet](#layer-0-externalinternet)
3. [Layer 1: Perimeter/Edge](#layer-1-perimeteredge)
4. [Layer 2: DMZ/API Gateway](#layer-2-dmzapi-gateway)
5. [Layer 3: Network](#layer-3-network)
6. [Layer 4: Compute/Container](#layer-4-computecontainer)
7. [Layer 5: Service Mesh](#layer-5-service-mesh)
8. [Layer 6: Application](#layer-6-application)
9. [Layer 7: Data](#layer-7-data)
10. [Cross-Cutting Concerns](#cross-cutting-concerns)
11. [Validation Architecture](#validation-architecture)
12. [Current State Assessment](#current-state-assessment)
13. [Implementation Priorities](#implementation-priorities)

---

## Architecture Overview

Defense-in-depth model from outermost to innermost layer:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 0: EXTERNAL/INTERNET                             │
│  DDoS Protection ─── CDN/Edge ─── DNS Security ─── Threat Intelligence          │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 1: PERIMETER/EDGE                                │
│  WAF ─── Load Balancer ─── TLS Termination ─── Geo-blocking ─── Bot Detection   │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 2: DMZ/API GATEWAY                               │
│  API Gateway ─── Rate Limiting ─── Schema Validation ─── API Key Auth           │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 3: NETWORK                                       │
│  VPC/Subnets ─── Security Groups ─── NACLs ─── Microsegmentation ─── Zero Trust │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 4: COMPUTE/CONTAINER                             │
│  Container Isolation ─── Host Firewall ─── Runtime Security ─── Image Scanning  │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 5: SERVICE MESH                                  │
│  mTLS ─── Service Auth ─── Traffic Policies ─── Circuit Breakers                │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 6: APPLICATION                                   │
│  AuthN/AuthZ ─── Input Validation ─── Output Encoding ─── Business Logic        │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           LAYER 7: DATA                                          │
│  Encryption (rest/transit) ─── Row-Level Security ─── Column Encryption ─── ACL │
└─────────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           CROSS-CUTTING CONCERNS                                 │
│  Secrets Management ─── Audit Logging ─── SIEM ─── IDS/IPS ─── Key Management   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 0: External/Internet

**Goal**: Stop attacks before they reach your infrastructure

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| DDoS Protection | Absorb volumetric attacks | Cloudflare, AWS Shield, Akamai |
| CDN/Edge Cache | Reduce origin load, cache static content | CloudFront, Fastly, Cloudflare |
| DNS Security | Prevent DNS hijacking/spoofing | DNSSEC, DNS filtering |
| Threat Intelligence | Block known bad IPs/domains | Crowdstrike, Recorded Future |

### HIPAA/GDPR Relevance

- **Availability**: DDoS protection ensures system availability
- **Data Routing**: Geo-restrictions can enforce GDPR data residency requirements

### Implementation Considerations

- Configure DDoS thresholds based on expected traffic patterns
- Use anycast DNS for resilience
- Subscribe to threat intelligence feeds for proactive blocking

---

## Layer 1: Perimeter/Edge

**Goal**: Filter malicious traffic at the edge before it enters your network

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| WAF (Web Application Firewall) | Block OWASP Top 10, SQLi, XSS | AWS WAF, Cloudflare WAF, ModSecurity |
| Load Balancer | Distribute traffic, health checks | ALB, nginx, HAProxy |
| TLS Termination | Encrypt in transit, terminate SSL | Let's Encrypt, ACM |
| Geo-blocking | Block traffic from restricted regions | Cloudflare, WAF rules |
| Bot Detection | Filter automated attacks | Cloudflare Bot Management, PerimeterX |

### HIPAA/GDPR Relevance

- **Encryption in Transit**: TLS 1.2+ required for HIPAA
- **Data Residency**: Geo-blocking can enforce GDPR requirements

### WAF Rule Categories

```
┌─────────────────────────────────────────────┐
│              WAF Rule Sets                   │
├─────────────────────────────────────────────┤
│ • SQL Injection Prevention                  │
│ • Cross-Site Scripting (XSS) Prevention     │
│ • Local File Inclusion (LFI) Prevention     │
│ • Remote Code Execution Prevention          │
│ • Known Bad Inputs (CVE signatures)         │
│ • Rate-based Rules                          │
│ • IP Reputation Lists                       │
└─────────────────────────────────────────────┘
```

---

## Layer 2: DMZ/API Gateway

**Goal**: Control and validate all API traffic entering the application zone

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| API Gateway | Centralized API management | Kong, AWS API Gateway, Apigee |
| Rate Limiting | Prevent abuse, ensure fair usage | Kong, nginx, Redis |
| Schema Validation | Reject malformed requests | JSON Schema, OpenAPI validation |
| API Key/Token Auth | Identify and authenticate clients | Kong key-auth, JWT validation |
| Request/Response Transform | Sanitize, redact sensitive data | Kong plugins, custom middleware |
| IP Allowlisting | Restrict to known clients | nginx, security groups |

### HIPAA/GDPR Relevance

- **Access Control**: API key management and authentication
- **Audit Logging**: Log all API access for compliance
- **Data Minimization**: Response transformation can filter sensitive fields

### API Gateway Capabilities

**What it CAN validate:**
- Request structure (JSON schema)
- Required headers present
- API key format valid
- Rate limits
- IP blocking
- Request size limits

**What it CANNOT validate:**
- "Does this user own this study?"
- "Is this participant enrolled in this study?"
- "Is this data within allowed ranges for this study's protocol?"
- Business rules requiring application context

### Kong Gateway Example Configuration

```yaml
services:
  - name: chronicle-mobile-api
    url: http://backend:40320
    routes:
      - name: mobile-route
        paths: ["/api/mobile"]
        strip_path: true
    plugins:
      - name: key-auth
        config:
          key_names: ["X-Chronicle-App-Key"]
          hide_credentials: true
      - name: rate-limiting
        config:
          minute: 300
          policy: redis
      - name: request-validator
        config:
          body_schema: |
            {
              "type": "object",
              "required": ["studyId", "participantId"],
              "properties": {
                "studyId": {"type": "string", "format": "uuid"},
                "participantId": {"type": "string", "format": "uuid"}
              }
            }
```

---

## Layer 3: Network

**Goal**: Isolate and segment network traffic, enforce zero trust

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| VPC/Virtual Network | Isolated network boundary | AWS VPC, Azure VNet |
| Subnets (Public/Private) | Separate tiers (web, app, data) | VPC subnets |
| Security Groups | Instance-level firewall | AWS SG, Azure NSG |
| Network ACLs | Subnet-level stateless firewall | NACLs |
| Microsegmentation | Service-to-service isolation | Calico, Cilium, VMware NSX |
| Zero Trust Network | Never trust, always verify | BeyondCorp, Zscaler, Tailscale |
| Private Link/Endpoints | Access services without public internet | AWS PrivateLink, Azure Private Endpoint |

### HIPAA/GDPR Relevance

- **Network Isolation**: Protects PHI/PII, limits blast radius of breaches
- **Least Privilege**: Network ACLs enforce minimum necessary access

### Network Architecture Example

```
┌─────────────────────────────────────────────────────────────────┐
│                              VPC                                 │
│                                                                  │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │   Public Subnet     │    │   Public Subnet     │             │
│  │   (Load Balancer)   │    │   (NAT Gateway)     │             │
│  │                     │    │                     │             │
│  │  ┌───────────────┐  │    │  ┌───────────────┐  │             │
│  │  │  nginx/ALB    │  │    │  │  NAT Gateway  │  │             │
│  │  └───────┬───────┘  │    │  └───────┬───────┘  │             │
│  └──────────│──────────┘    └──────────│──────────┘             │
│             │                          │                         │
│             ▼                          │                         │
│  ┌─────────────────────────────────────│────────────────────┐   │
│  │              Private Subnet (Application)                │   │
│  │                                     │                    │   │
│  │  ┌─────────────┐  ┌─────────────┐   │                    │   │
│  │  │   Backend   │  │   Backend   │   │ (outbound only)    │   │
│  │  │  (App 1)    │  │  (App 2)    │◄──┘                    │   │
│  │  └──────┬──────┘  └──────┬──────┘                        │   │
│  └─────────│────────────────│───────────────────────────────┘   │
│            │                │                                    │
│            ▼                ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                Private Subnet (Data)                      │   │
│  │                                                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │   │
│  │  │  PostgreSQL │  │    Redis    │  │   S3/Minio  │       │   │
│  │  │   Primary   │  │   Cluster   │  │   Storage   │       │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘       │   │
│  │                                                           │   │
│  │  NO INTERNET ACCESS - Isolated from public subnets       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Security Group Rules Example

```
┌─────────────────────────────────────────────────────────────┐
│                    Security Group: sg-backend                │
├─────────────────────────────────────────────────────────────┤
│ INBOUND:                                                     │
│   • TCP 40320 from sg-loadbalancer (API traffic)            │
│   • TCP 22 from sg-bastion (SSH for emergencies)            │
│                                                              │
│ OUTBOUND:                                                    │
│   • TCP 5432 to sg-database (PostgreSQL)                    │
│   • TCP 6379 to sg-redis (Cache)                            │
│   • TCP 443 to 0.0.0.0/0 (External APIs via NAT)            │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer 4: Compute/Container

**Goal**: Isolate workloads, secure the runtime environment

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| Container Isolation | Process/namespace isolation | Docker, containerd, gVisor |
| Pod Security | Restrict container privileges | K8s Pod Security Standards, OPA |
| Image Scanning | Detect vulnerabilities in images | Trivy, Snyk, Clair |
| Runtime Security | Detect anomalous behavior | Falco, Sysdig, Aqua |
| Host Hardening | Minimize attack surface | CIS Benchmarks, SELinux, AppArmor |
| Immutable Infrastructure | No SSH, no manual changes | Terraform, GitOps |
| Resource Limits | Prevent noisy neighbor/DoS | K8s resource quotas, cgroups |

### HIPAA/GDPR Relevance

- **Workload Isolation**: Prevents lateral movement between services
- **Vulnerability Management**: Required for maintaining secure systems

### Container Security Best Practices

```dockerfile
# Dockerfile security best practices
FROM openjdk:17-slim

# Run as non-root user
RUN useradd -r -u 1001 chronicle
USER chronicle

# Don't store secrets in image
# Use environment variables or secrets management

# Minimize attack surface - no shell if not needed
# Use distroless images where possible

# Set resource limits in orchestration
# HEALTHCHECK for container health monitoring
HEALTHCHECK --interval=30s --timeout=3s \
  CMD curl -f http://localhost:40320/health || exit 1
```

### Kubernetes Pod Security Example

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: chronicle-backend
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    fsGroup: 1001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: backend
      image: chronicle-backend:latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
      resources:
        limits:
          memory: "2Gi"
          cpu: "1000m"
        requests:
          memory: "512Mi"
          cpu: "250m"
```

---

## Layer 5: Service Mesh

**Goal**: Secure and control service-to-service communication

*Note: This layer is most relevant for microservices architectures. Chronicle is currently a monolith, so this layer is informational for future scaling.*

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| mTLS | Encrypt and authenticate service traffic | Istio, Linkerd, Consul Connect |
| Service Identity | Cryptographic identity per service | SPIFFE/SPIRE |
| Authorization Policies | Which service can call which | Istio AuthorizationPolicy, OPA |
| Traffic Policies | Retry, timeout, circuit breaker | Istio, Linkerd |
| Observability | Distributed tracing, metrics | Jaeger, Zipkin, Prometheus |

### HIPAA/GDPR Relevance

- **Least Privilege**: Service-to-service authorization
- **Audit Trail**: Distributed tracing of all service calls
- **Encryption**: mTLS ensures encryption between services

### Service Mesh Authorization Policy Example

```yaml
# Only frontend can call backend, only backend can call database
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: backend-policy
  namespace: chronicle
spec:
  selector:
    matchLabels:
      app: chronicle-backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/chronicle/sa/frontend"
              - "cluster.local/ns/chronicle/sa/api-gateway"
      to:
        - operation:
            methods: ["GET", "POST", "PUT", "DELETE"]
```

---

## Layer 6: Application

**Goal**: Enforce business logic, authentication, authorization, input/output handling

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| Authentication (AuthN) | Verify identity | OAuth2, OIDC, SAML, JWT |
| Authorization (AuthZ) | Verify permissions | RBAC, ABAC, OPA, Casbin |
| Input Validation | Reject malformed/malicious input | Bean Validation, JSON Schema |
| Output Encoding | Prevent XSS | Context-aware encoding |
| CSRF Protection | Prevent cross-site request forgery | CSRF tokens, SameSite cookies |
| Session Management | Secure session handling | Secure cookies, token rotation |
| Business Logic Validation | Domain-specific rules | Application code |
| Error Handling | Don't leak sensitive info | Generic error messages |

### HIPAA/GDPR Relevance

This layer is where compliance is primarily enforced:

| Requirement | Implementation |
|-------------|----------------|
| Access Control | Role-based permissions, "minimum necessary" principle |
| Audit Trail | Log all access to PHI/PII with user, timestamp, action |
| Consent Management | Track and enforce consent (GDPR) |
| Data Subject Rights | Export, delete, rectify endpoints (GDPR) |
| Break-glass Access | Emergency access with elevated logging |
| Accounting of Disclosures | Track all PHI disclosures (HIPAA) |

### Input Validation Implementation

```kotlin
// Bean Validation annotations (JSR-380)
data class ParticipantEnrollment(
    @field:NotNull(message = "Study ID is required")
    @field:ValidUUID(message = "Study ID must be a valid UUID")
    val studyId: UUID,

    @field:NotNull(message = "Participant ID is required")
    @field:ValidUUID(message = "Participant ID must be a valid UUID")
    val participantId: UUID,

    @field:NotNull(message = "Device information is required")
    @field:Valid
    val device: DeviceInfo,

    @field:Size(max = 1000, message = "Additional info must be under 1000 characters")
    val additionalInfo: String? = null
)

data class DeviceInfo(
    @field:NotBlank(message = "Device model is required")
    @field:Size(max = 100)
    val model: String,

    @field:NotBlank(message = "OS version is required")
    @field:Pattern(regexp = "^[0-9.]+$", message = "Invalid OS version format")
    val osVersion: String,

    @field:NotBlank(message = "Device ID is required")
    @field:Size(min = 16, max = 64)
    val deviceId: String
)

// Controller with validation
@RestController
class EnrollmentController(private val enrollmentService: EnrollmentService) {

    @PostMapping("/chronicle/v3/study/{studyId}/participant/{participantId}/enroll")
    fun enrollParticipant(
        @PathVariable @ValidUUID studyId: UUID,
        @PathVariable @ValidUUID participantId: UUID,
        @Valid @RequestBody enrollment: ParticipantEnrollment
    ): ResponseEntity<EnrollmentResponse> {
        // Validation happens automatically before this code runs
        return ResponseEntity.ok(enrollmentService.enroll(enrollment))
    }
}
```

### Authorization Pattern

```kotlin
// Role-Based Access Control
enum class Permission {
    STUDY_READ,
    STUDY_WRITE,
    STUDY_DELETE,
    PARTICIPANT_READ,
    PARTICIPANT_WRITE,
    DATA_EXPORT,
    ADMIN
}

enum class Role(val permissions: Set<Permission>) {
    PARTICIPANT(setOf(Permission.PARTICIPANT_READ)),
    RESEARCHER(setOf(Permission.STUDY_READ, Permission.PARTICIPANT_READ, Permission.PARTICIPANT_WRITE)),
    STUDY_ADMIN(setOf(Permission.STUDY_READ, Permission.STUDY_WRITE, Permission.PARTICIPANT_READ,
                      Permission.PARTICIPANT_WRITE, Permission.DATA_EXPORT)),
    SYSTEM_ADMIN(Permission.values().toSet())
}

// Authorization check
@PreAuthorize("hasPermission(#studyId, 'STUDY', 'READ')")
fun getStudy(studyId: UUID): Study {
    // Only executes if user has STUDY_READ permission for this study
}
```

---

## Layer 7: Data

**Goal**: Protect data at rest, enforce access controls at the data level

### Components

| Component | Purpose | Tools |
|-----------|---------|-------|
| Encryption at Rest | Protect stored data | AES-256, KMS-managed keys |
| Encryption in Transit | Protect data in motion | TLS 1.3 |
| Column-Level Encryption | Encrypt specific PII/PHI fields | Application-level, pgcrypto |
| Row-Level Security | Users only see their data | PostgreSQL RLS, application logic |
| Data Masking | Redact sensitive data in non-prod | Dynamic masking, Delphix |
| Database Access Control | Principle of least privilege | Separate DB users per service |
| Backup Encryption | Protect backups | Encrypted snapshots |
| Data Classification | Tag sensitive data | Automated PII detection |

### HIPAA/GDPR Relevance

- **Encryption Requirements**: HIPAA requires encryption of PHI at rest and in transit
- **Data Minimization**: Only store what's necessary (GDPR)
- **Access Controls**: Restrict access to minimum necessary

### PostgreSQL Row-Level Security Example

```sql
-- Enable RLS on tables containing PHI
ALTER TABLE participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE sensor_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE survey_responses ENABLE ROW LEVEL SECURITY;

-- Create policy: Researchers can only see participants in their studies
CREATE POLICY study_participant_isolation ON participants
    FOR ALL
    USING (
        study_id IN (
            SELECT study_id
            FROM study_members
            WHERE user_id = current_setting('app.current_user_id')::uuid
        )
    );

-- Create policy: Data access restricted to study members
CREATE POLICY study_data_isolation ON sensor_data
    FOR SELECT
    USING (
        study_id IN (
            SELECT study_id
            FROM study_members
            WHERE user_id = current_setting('app.current_user_id')::uuid
              AND role IN ('RESEARCHER', 'STUDY_ADMIN', 'SYSTEM_ADMIN')
        )
    );

-- Participants can only see their own data
CREATE POLICY participant_own_data ON sensor_data
    FOR SELECT
    USING (
        participant_id = current_setting('app.current_participant_id')::uuid
    );
```

### Column-Level Encryption Example

```sql
-- Create extension for encryption
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Table with encrypted PII columns
CREATE TABLE participants (
    id UUID PRIMARY KEY,
    study_id UUID NOT NULL REFERENCES studies(id),

    -- Encrypted PII fields
    email_encrypted BYTEA,  -- pgp_sym_encrypt(email, key)
    phone_encrypted BYTEA,  -- pgp_sym_encrypt(phone, key)

    -- Non-PII fields stored normally
    enrollment_date TIMESTAMP NOT NULL,
    status VARCHAR(50) NOT NULL,

    -- Searchable hash for lookups (can't decrypt, but can match)
    email_hash VARCHAR(64) GENERATED ALWAYS AS (
        encode(sha256(email_encrypted), 'hex')
    ) STORED
);

-- Encrypt on insert (done in application layer)
-- INSERT INTO participants (email_encrypted)
-- VALUES (pgp_sym_encrypt('user@example.com', current_setting('app.encryption_key')));

-- Decrypt on select (done in application layer)
-- SELECT pgp_sym_decrypt(email_encrypted, current_setting('app.encryption_key')) as email
-- FROM participants WHERE id = ?;
```

---

## Cross-Cutting Concerns

These concerns span all layers and must be addressed holistically.

### Secrets Management

| Component | Purpose | Tools |
|-----------|---------|-------|
| Secrets Vault | Centralized secret storage | HashiCorp Vault, AWS Secrets Manager |
| Dynamic Secrets | Short-lived credentials | Vault database secrets engine |
| Key Rotation | Regularly rotate keys | Automated rotation policies |
| No Hardcoded Secrets | Secrets never in code | Pre-commit hooks, scanning |

#### Vault Integration Example

```yaml
# docker-compose with Vault
services:
  vault:
    image: vault:1.15
    cap_add:
      - IPC_LOCK
    environment:
      VAULT_DEV_ROOT_TOKEN_ID: "dev-token"  # Only for dev!
    ports:
      - "8200:8200"

  backend:
    environment:
      VAULT_ADDR: "http://vault:8200"
      VAULT_TOKEN: "${VAULT_TOKEN}"  # Injected at runtime
```

```kotlin
// Application fetches secrets from Vault
class VaultSecretProvider(private val vaultClient: VaultClient) {

    fun getDatabaseCredentials(): DatabaseCredentials {
        val secret = vaultClient.logical()
            .read("database/creds/chronicle-backend")

        return DatabaseCredentials(
            username = secret.data["username"] as String,
            password = secret.data["password"] as String
        )
    }
}
```

### Audit Logging

| Component | Purpose | Tools |
|-----------|---------|-------|
| Centralized Logging | Aggregate all logs | ELK, Splunk, Datadog |
| Audit Trail | Who did what when | Immutable audit logs |
| SIEM | Security event correlation | Splunk, Sentinel, Sumo Logic |
| Alerting | Real-time security alerts | PagerDuty, Opsgenie |

#### HIPAA-Compliant Audit Log Structure

```kotlin
data class AuditLogEntry(
    val id: UUID = UUID.randomUUID(),
    val timestamp: Instant = Instant.now(),

    // Who
    val userId: UUID?,
    val userRole: String?,
    val ipAddress: String,
    val userAgent: String,

    // What
    val action: AuditAction,
    val resourceType: String,      // "Study", "Participant", "SensorData"
    val resourceId: UUID?,

    // Context
    val studyId: UUID?,
    val participantId: UUID?,

    // Outcome
    val success: Boolean,
    val errorMessage: String?,

    // PHI indicator
    val accessedPHI: Boolean,
    val phiFields: List<String>?   // ["email", "dateOfBirth"]
)

enum class AuditAction {
    // Authentication
    LOGIN, LOGOUT, LOGIN_FAILED,

    // Data Access
    VIEW, SEARCH, EXPORT, DOWNLOAD,

    // Data Modification
    CREATE, UPDATE, DELETE,

    // Administrative
    PERMISSION_CHANGE, SETTINGS_CHANGE,

    // Special
    BREAK_GLASS_ACCESS, CONSENT_GIVEN, CONSENT_WITHDRAWN
}
```

### Intrusion Detection

| Component | Purpose | Tools |
|-----------|---------|-------|
| IDS/IPS | Detect/prevent intrusions | Suricata, Snort, AWS GuardDuty |
| UEBA | User behavior anomaly detection | Exabeam, Securonix |
| File Integrity | Detect unauthorized changes | OSSEC, Tripwire |

---

## Validation Architecture

### Where Should Validation Happen?

| Layer | What to Validate | Security Value | HIPAA/GDPR Value |
|-------|------------------|----------------|------------------|
| Client (Browser/App) | Format, required fields | None (bypassable) | None |
| Gateway | Schema, rate limits, API keys | Medium (defense in depth) | Partial |
| Backend | Everything + business logic | Critical (authoritative) | Critical |

### Validation Comparison

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        VALIDATION RESPONSIBILITIES                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  CLIENT (Optional - UX only)                                                │
│  ├── Field format validation                                                │
│  ├── Required field presence                                                │
│  └── Immediate user feedback                                                │
│      ⚠️  Can always be bypassed - NEVER trust                              │
│                                                                              │
│  GATEWAY (Recommended - Defense in Depth)                                   │
│  ├── JSON schema validation                                                 │
│  ├── Request size limits                                                    │
│  ├── Rate limiting                                                          │
│  ├── API key presence/format                                                │
│  └── IP allowlisting/blocklisting                                           │
│      ✓  Rejects bad traffic early                                          │
│      ✗  Cannot validate business logic                                      │
│                                                                              │
│  BACKEND (Mandatory - Authoritative)                                        │
│  ├── All structural validation (redundant with gateway)                     │
│  ├── Authentication verification                                            │
│  ├── Authorization (can this user access this resource?)                    │
│  ├── Business rules (is this participant enrolled?)                         │
│  ├── Referential integrity (does this study exist?)                         │
│  └── Data integrity (are values within allowed ranges?)                     │
│      ✓  Full context available                                             │
│      ✓  Single source of truth                                             │
│      ✓  Where compliance is enforced                                       │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Security Attack Mitigation by Layer

| Attack Vector | Client | Gateway | Backend |
|---------------|--------|---------|---------|
| SQL Injection | ❌ | Partial (schema) | ✅ Parameterized queries |
| XSS | ❌ | ❌ | ✅ Output encoding |
| CSRF | ❌ | ❌ | ✅ Token validation |
| Brute Force | ❌ | ✅ Rate limiting | ✅ Account lockout |
| Data Exfiltration | ❌ | ❌ | ✅ Authorization |
| Malformed Input | Partial | ✅ Schema | ✅ Full validation |
| Unauthorized Access | ❌ | Partial | ✅ AuthZ checks |

---

## Current State Assessment

### Chronicle Security Posture

| Layer | Current State | Remaining Gaps | Risk |
|-------|---------------|----------------|------|
| 0: External | None | No DDoS protection | Medium |
| 1: Perimeter | Traefik with rate limiting, security headers, CSP | No WAF | Low |
| 2: API Gateway | Traefik path-based routing, CORS, HMAC signing for mobile | No schema validation at gateway | Low |
| 3: Network | Docker internal network, SSRF prevention | Basic isolation, no microsegmentation | Medium |
| 4: Container | Docker, Trivy image scanning in CI | No runtime security | Low |
| 5: Service Mesh | N/A | N/A (monolith architecture) | N/A |
| 6: Application | Bean Validation, RBAC auth checks, Jackson hardening, request validation | — | Low |
| 7: Data | pg_tde TDE, SSL/TLS in transit, RLS (17 tables), parameterized queries | No column-level encryption (mitigated by TDE) | Low |
| Cross-cutting | Dual-write audit logging (DB + file), Prometheus + Grafana + AlertManager monitoring, CVE scanning | No secrets vault in production | Low |

### Validation Current State

| Component | Status | Details |
|-----------|--------|---------|
| Jackson (JSON parsing) | ✅ Hardened | @JsonProperty annotations, polymorphic type restrictions |
| Bean Validation | ✅ Implemented | @Valid, @NotNull, @NotBlank on DTOs and controllers |
| Custom Validation | ✅ Implemented | SQL identifier allowlist, null byte rejection, request validation |
| Gateway Schema Validation | Partial | Traefik path-based routing + rate limiting; no full schema validation at gateway |

---

## Implementation Priorities

### For HIPAA/GDPR Compliance

| Priority | Layer | Action | Status |
|----------|-------|--------|--------|
| ~~**P0**~~ | ~~Application~~ | ~~Add Bean Validation to DTOs and controllers~~ | ~~COMPLETED~~ |
| ~~**P0**~~ | ~~Application~~ | ~~Implement proper authorization checks~~ | ~~COMPLETED~~ |
| ~~**P0**~~ | ~~Application~~ | ~~Add comprehensive audit logging~~ | ~~COMPLETED~~ |
| ~~**P0**~~ | ~~Data~~ | ~~Enable encryption at rest~~ | ~~COMPLETED~~ |
| ~~**P1**~~ | ~~Data~~ | ~~Implement row-level security~~ | ~~COMPLETED (17 tables)~~ |
| **P1** | API Gateway | Add schema validation (Kong or nginx) | Open |
| ~~**P1**~~ | ~~API Gateway~~ | ~~Proper API key management + HMAC signing~~ | ~~COMPLETED~~ |
| **P1** | Cross-cutting | Implement secrets management (Vault) | Open |
| **P2** | Perimeter | Add WAF | Open |
| ~~**P2**~~ | ~~Data~~ | ~~Column-level encryption for PII~~ | ~~Skipped (TDE covers full rows)~~ |
| **P2** | Network | Proper subnet isolation | Open |
| **P3** | External | DDoS protection | Open |
| ~~**P3**~~ | ~~Container~~ | ~~Image scanning~~ | ~~COMPLETED (Trivy in CI)~~ |

### Quick Wins

1. ~~**Enable PostgreSQL encryption at rest**~~ - COMPLETED: Using Percona pg_tde with TDE
2. ~~**Add Bean Validation annotations**~~ - COMPLETED: @NotNull, @NotBlank, @Size on DTOs
3. ~~**Add @Valid to @RequestBody parameters**~~ - COMPLETED: All controllers annotated
4. ~~**Improve audit logging**~~ - COMPLETED: Dual-write (DB + file), JSON format for SIEM
5. ~~**API key validation in backend**~~ - COMPLETED: HMAC signing + replay prevention

### Implementation Sequence

```
Phase 1: Application Security — COMPLETED
├── ✓ Bean Validation on all DTOs
├── ✓ @Valid on all @RequestBody parameters
├── ✓ RBAC authorization service
├── ✓ Dual-write audit logging (DB + file)
└── ✓ Jackson hardening, request validation, SSRF prevention

Phase 2: Data Security — COMPLETED
├── ✓ PostgreSQL encryption at rest (pg_tde)
├── ✓ PostgreSQL SSL/TLS (encryption in transit)
├── ✓ Row-level security (17 tables)
├── — Column encryption skipped (TDE covers full rows)
└── ✓ SQL identifier allowlist validation

Phase 3: Infrastructure Security — PARTIAL
├── — API gateway schema validation (open)
├── — Vault for secrets management (open, file-based TDE keys in use)
├── — WAF rules (open)
├── ✓ Rate limiting (Traefik + Bucket4j)
└── ✓ CORS, CSP, security headers

Phase 4: Advanced Security — PARTIAL
├── ✓ Container image scanning (Trivy in CI)
├── — Container runtime security (open)
├── — Network microsegmentation (open)
├── ✓ SIEM integration (Loki + Promtail + Grafana audit dashboard)
└── ✓ Prometheus alerting (AlertManager)
```

---

## References

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [HIPAA Security Rule](https://www.hhs.gov/hipaa/for-professionals/security/index.html)
- [GDPR Article 32 - Security of Processing](https://gdpr-info.eu/art-32-gdpr/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [CIS Controls](https://www.cisecurity.org/controls)
- [Zero Trust Architecture - NIST SP 800-207](https://csrc.nist.gov/publications/detail/sp/800-207/final)
