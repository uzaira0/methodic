# Chronicle Security Hardening

This document describes the security measures implemented to protect Chronicle against common attacks.

## Overview

| Layer | Protection | Status |
|-------|------------|--------|
| Data | PostgreSQL TDE (encryption at rest) | ✓ Implemented |
| Data | PostgreSQL SSL/TLS (encryption in transit) | ✓ Implemented |
| Data | Row-Level Security (study isolation) | ✓ Implemented |
| Data | SQL Injection Prevention (parameterized queries) | ✓ Implemented |
| Data | SQL Identifier Validation (allowlist validation) | ✓ Implemented |
| Application | Bean Validation (input validation) | ✓ Implemented |
| Application | Controller @Valid annotations | ✓ Implemented |
| Authorization | RBAC with study permissions | ✓ Implemented |
| Audit | Dual-write logging (DB + file) | ✓ Implemented |
| Serialization | Jackson hardening | ✓ Implemented |
| HTTP | TRACE method blocking | ✓ Implemented |
| HTTP | Request validation (null bytes) | ✓ Implemented |
| HTTP | Application-level security headers | ✓ Implemented |
| HTTP | CSP + security headers | ✓ Implemented |
| HTTP | Open redirect prevention | ✓ Implemented |
| HTTP | HTTP Parameter Pollution (HPP) prevention | ✓ Implemented |
| Crypto | Constant-time secret comparison | ✓ Implemented |
| Logging | Log injection sanitization | ✓ Implemented |
| XML | XXE (XML External Entity) prevention | ✓ Implemented |
| Server | Jetty hardening | ✓ Implemented |
| Mobile API | HMAC request signing | ✓ Implemented |
| Mobile API | Replay attack prevention | ✓ Implemented |
| HTTP | CORS (Cross-Origin Resource Sharing) security | ✓ Implemented |
| HTTP | SameSite cookie protection | ✓ Implemented |
| Rate Limiting | Distributed rate limiting (Bucket4j + Hazelcast) | ✓ Implemented |
| Network | SSRF (Server-Side Request Forgery) prevention | ✓ Implemented |
| Dependencies | CVE scanning (OWASP + npm audit) | ✓ Implemented |
| Error Handling | Error Response Sanitization | ✓ Implemented |

---

## Implemented Protections

### PostgreSQL Transparent Data Encryption (TDE)
**What**: Encrypts data files on disk using AES-256.
**Why**: Protects against physical disk theft and unauthorized filesystem access.
**Files**: `docker/init-db-encryption.sh`, `docker/verify-encryption.sh`

### PostgreSQL SSL/TLS Encryption (Encryption in Transit)
**What**: TLS 1.2+ encryption for all connections between Chronicle backend and PostgreSQL.
**Why**: Protects PHI/PII from network sniffing attacks. Required for HIPAA compliance (164.312(e)(2)(ii)).
**Files**: `docker/init-postgres-ssl.sh`, `docker/postgres-ssl/`, `docker-compose.prod.yml`, `docker-compose.traefik.yml`

#### SSL Modes

| Mode | Encryption | Server Cert Validation | Use Case |
|------|------------|------------------------|----------|
| `disable` | No | No | Never use in production |
| `require` | **Yes** | No | Minimum for HIPAA compliance |
| `verify-ca` | **Yes** | CA validation | Good for production |
| `verify-full` | **Yes** | CA + hostname | **Recommended for production** |

#### Quick Setup

```bash
cd docker

# 1. Generate certificates (development - self-signed)
./init-postgres-ssl.sh --dev

# 2. Configure environment
cp .env.example .env
# Set POSTGRES_SSL_MODE=require (minimum) or verify-full (recommended)

# 3. Deploy with SSL
docker-compose -f docker-compose.prod.yml up -d

# 4. Verify SSL is working
docker exec chronicle-postgres psql -U chronicle -c "SHOW ssl;"
# Expected: on
```

#### Verification

```bash
# Check SSL is enabled
docker exec chronicle-postgres psql -U chronicle -c "SHOW ssl;"

# Check active connections are using SSL
docker exec chronicle-postgres psql -U chronicle -c "
SELECT ssl, version FROM pg_stat_ssl
JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid
WHERE datname = 'chronicle';"

# Verify certificate chain
docker exec chronicle-postgres openssl verify \
    -CAfile /var/lib/postgresql/ssl/ca.crt \
    /var/lib/postgresql/ssl/server.crt
```

#### Certificate Management

Certificates are stored in `docker/postgres-ssl/`:
- `ca/ca.crt` - Certificate Authority (10-year validity)
- `server/server.crt` - PostgreSQL server certificate (1-year validity)
- `client/client.crt` - Client certificate for mTLS (optional)

To renew certificates:
```bash
./init-postgres-ssl.sh --renew
docker-compose -f docker-compose.prod.yml restart postgres backend
```

#### Production Recommendations

1. **Use `verify-full`** mode for maximum security
2. **Replace self-signed certs** with CA-signed certificates
3. **Set up certificate rotation** before expiration (30-day warning recommended)
4. **Monitor certificate expiration** with alerting
5. **Consider mTLS** for additional client authentication

### Row-Level Security (RLS)
**What**: Database-enforced study isolation - users can only query data from authorized studies.
**Why**: Defense-in-depth. Even if application auth is bypassed, database enforces isolation.
**Files**: `V1__enable_row_level_security.sql`, `RLSContextManager.kt`

### SQL Injection Prevention
**What**: Comprehensive protection against SQL injection attacks through parameterized queries and identifier validation.
**Why**: SQL injection remains one of the top web application vulnerabilities (OWASP Top 10). It can lead to data theft, data manipulation, and complete system compromise.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/SqlIdentifierValidator.kt`, `scripts/audit-sql-injection.sh`, `docs/SQL-SECURITY-GUIDELINES.md`

#### Protection Layers

| Layer | Protection | Implementation |
|-------|------------|----------------|
| Values | Parameterized queries | `PreparedStatement` with `?` or `:paramName` |
| Table names | Allowlist validation | `SqlIdentifierValidator.validateTableName()` |
| Temp tables | Prefix + pattern validation | `SqlIdentifierValidator.validateTempTableName()` |
| Import tables | Pattern validation | `SqlIdentifierValidator.validateImportTableName()` |
| Timeouts | Numeric validation | `SqlIdentifierValidator.validateTimeout()` |

#### SqlIdentifierValidator Usage

```kotlin
import com.openlattice.chronicle.util.SqlIdentifierValidator

// Validate known table names against allowlist
val table = SqlIdentifierValidator.validateTableName("participants")
stmt.execute("SELECT * FROM $table")

// Validate dynamically generated temp table names
val tempTable = SqlIdentifierValidator.validateTempTableName(
    "duplicate_events_${RandomStringUtils.randomAlphanumeric(10)}"
)
stmt.execute("CREATE TEMPORARY TABLE $tempTable ...")

// Validate import table names from configuration
val sourceTable = SqlIdentifierValidator.validateImportTableName(config.tableName)
stmt.execute("SELECT * FROM $sourceTable")

// Validate numeric timeout values
val timeout = SqlIdentifierValidator.validateTimeout(timeoutMillis)
stmt.execute("SET statement_timeout = '${timeout}ms'")
```

#### Allowed Temp Table Prefixes

Only these prefixes are allowed for dynamically generated temporary tables:
- `duplicate_events_`
- `duplicate_ios_events_`
- `temp_`
- `tmp_`

#### Running the SQL Audit Script

```bash
# Run SQL injection vulnerability audit
./scripts/audit-sql-injection.sh

# Verbose mode with context
./scripts/audit-sql-injection.sh --verbose
```

The audit script checks for:
- String interpolation in `createQuery()`, `createUpdate()`, `execute()`
- String concatenation with SQL keywords
- Dynamic table/column name references
- Unvalidated temp table names
- Statement timeout interpolation

#### CVEs Mitigated
- CWE-89: SQL Injection
- OWASP Top 10 A03:2021 - Injection
- Various SQL injection attack patterns including:
  - Second-order SQL injection (stored values)
  - Blind SQL injection
  - Union-based SQL injection

For detailed guidelines, see [SQL-SECURITY-GUIDELINES.md](./SQL-SECURITY-GUIDELINES.md).

### Bean Validation
**What**: Jakarta Validation annotations on DTOs (@NotBlank, @Size, @Pattern, etc.)
**Why**: Rejects malformed input at the earliest point, before business logic.
**Files**: 29 DTO files in `chronicle-api`

### Controller Validation
**What**: @Valid annotation on all @RequestBody parameters, @Validated on controllers.
**Why**: Triggers Bean Validation, returns 400 with specific field errors.
**Files**: 17 controllers in `chronicle-server`

### RBAC Authorization
**What**: Role-based access control with study-level permissions.
**Why**: Enforces least-privilege access to research data.
**Files**: `StudyAuthorizationService.kt`, `@RequiresStudyAccess` annotation

### Audit Logging
**What**: Every sensitive action logged to database AND log file.
**Why**: HIPAA compliance, forensics, anomaly detection.
**Files**: `AuditService.kt`, `logback-spring.xml`

### Content Security Policy (CSP) and Security Headers
**What**: Comprehensive HTTP security headers at the nginx reverse proxy layer.
**Why**: Defense-in-depth against XSS, data injection, clickjacking, MIME sniffing, and information leakage.
**Files**: `docker/nginx.prod.conf`, `docker/nginx.frontend.conf`

#### Implemented Headers

| Header | Value | Purpose |
|--------|-------|---------|
| Content-Security-Policy | See below | Controls resource loading, prevents XSS |
| X-Frame-Options | DENY | Prevents clickjacking via iframe embedding |
| X-Content-Type-Options | nosniff | Prevents MIME type sniffing |
| Referrer-Policy | strict-origin-when-cross-origin | Limits referrer header information leakage |
| Strict-Transport-Security | max-age=31536000; includeSubDomains; preload | Enforces HTTPS |
| Cross-Origin-Opener-Policy | same-origin | Isolates browsing context |
| Cross-Origin-Resource-Policy | same-origin | Prevents cross-origin resource loading |
| Permissions-Policy | Disabled: accelerometer, camera, geolocation, gyroscope, magnetometer, microphone, payment, usb | Restricts browser feature access |

#### CSP Directives

```
default-src 'self';
script-src 'self' 'sha256-u5x2jPc3qq6tXCxclhc2AsfuAh6gqS+FdKid5mVKr8U=' https://www.googletagmanager.com https://www.google-analytics.com https://cdn.auth0.com;
style-src 'self' 'unsafe-inline' https://cdn.auth0.com https://rsms.me;
img-src 'self' data: https://cdn.auth0.com https://www.google-analytics.com;
font-src 'self' https://rsms.me https://cdn.auth0.com;
connect-src 'self' https://methodic.us.auth0.com https://www.google-analytics.com https://www.googletagmanager.com;
frame-src 'self' https://methodic.us.auth0.com;
frame-ancestors 'none';
form-action 'self';
worker-src 'self' blob:;
base-uri 'self';
object-src 'none';
```

**CSP Design Decisions:**
- **script-src with hash**: Uses SHA256 hash for the inline Google Analytics script instead of 'unsafe-inline' for stronger security
- **style-src 'unsafe-inline'**: Required for React styled-components which inject inline styles at runtime
- **External domains whitelisted**: Only Auth0 (authentication), Google Analytics (tracking), and rsms.me (Inter font)
- **frame-ancestors 'none'**: Prevents embedding in any iframe (stronger than X-Frame-Options)
- **object-src 'none'**: Blocks Flash/Java plugins completely
- **base-uri 'self'**: Prevents base tag hijacking

**Note on SRI (Subresource Integrity):**
External scripts (Google Analytics, Inter font) are loaded via CDN and would benefit from SRI. However:
- Google Analytics scripts are dynamic and change frequently, making SRI impractical
- The Inter font is loaded via CSS from rsms.me, which doesn't support SRI for CSS
- All bundled JavaScript is served from same-origin, so SRI provides limited benefit

### Jetty Server Hardening
**What**: Comprehensive security hardening for embedded Jetty server to prevent DoS attacks, request smuggling, and resource exhaustion.
**Why**: Default Jetty settings are permissive for development but need hardening for production. Protects against slow loris attacks, large payload DoS, header bomb attacks, and information disclosure.
**Files**: `rhizome/src/main/java/com/geekbeast/rhizome/configuration/jetty/HardeningConfiguration.java`, `rhizome/src/main/java/com/geekbeast/rhizome/core/JettyLoam.java`

#### Attack Mitigations

| Attack | Mitigation | Setting |
|--------|------------|---------|
| Slow Loris | Aggressive idle timeout kills slow connections | `idle-timeout: 30000` (30s) |
| Large Payload DoS | Reject oversized request bodies | `max-form-content-size: 10485760` (10MB) |
| Header Bomb | Limit request/response header sizes | `request-header-size: 8192` (8KB) |
| Hash Collision | Limit form parameter count | `max-form-keys: 1000` |
| Resource Exhaustion | Bounded thread pool | `min-threads: 8`, `max-threads: 200` |
| Information Disclosure | Don't send server version | `send-server-version: false` |

#### Configuration

The hardening configuration is embedded in `jetty.yaml` and defaults to secure values if not specified:

```yaml
# jetty.yaml
hardening:
  # Connection timeouts (milliseconds)
  idle-timeout: 30000      # 30 seconds - kills slow loris attacks

  # Request size limits (bytes)
  request-header-size: 8192    # 8KB - prevents header bomb
  response-header-size: 8192   # 8KB - prevents response header abuse
  max-form-content-size: 10485760  # 10MB - prevents large payload DoS
  max-form-keys: 1000          # prevents hash collision attacks
  output-buffer-size: 32768    # 32KB

  # Thread pool bounds
  min-threads: 8               # minimum worker threads
  max-threads: 200             # maximum worker threads

  # Response hardening
  send-server-version: false   # don't disclose Jetty version
  send-date-header: true       # standard HTTP behavior
```

#### How It Works

1. **Thread Pool Hardening**: The `QueuedThreadPool` is configured with bounded min/max threads to prevent resource exhaustion. The idle timeout ensures inactive threads are reclaimed.

2. **HTTP Configuration Hardening**: Each connector's `HttpConfiguration` is configured with:
   - Request/response header size limits (prevents header bomb attacks)
   - Output buffer sizing
   - Server version suppression (prevents information disclosure)

3. **Connector Hardening**: Each `ServerConnector` (HTTP and HTTPS) is configured with:
   - Idle timeout to kill slow connections (prevents slow loris attacks)

4. **Context Hardening**: The `WebAppContext` is configured with:
   - Maximum form content size (prevents large payload DoS)
   - Maximum form keys (prevents hash collision attacks)

#### Verification

```bash
# Test that server version is not disclosed
curl -I http://localhost:8081/chronicle/healthcheck 2>/dev/null | grep -i "server"
# Should NOT show "Jetty" or any version number

# Test header size limit (send oversized header)
curl -v -H "X-Test: $(head -c 10000 /dev/zero | tr '\0' 'A')" http://localhost:8081/chronicle/healthcheck
# Should return 431 Request Header Fields Too Large

# Test form content size limit
dd if=/dev/zero bs=1M count=15 2>/dev/null | curl -X POST -d @- http://localhost:8081/chronicle/test
# Should return 413 Request Entity Too Large

# Check hardening settings in startup logs
grep "Applying Jetty security hardening" /var/log/chronicle/server.log
```

### Dependency Vulnerability Scanning
**What**: Automated scanning of all dependencies for known CVEs before deployment.
**Why**: Libraries like Log4j, Jackson, and Spring have had critical vulnerabilities. Transitive dependencies may include vulnerable libraries without your knowledge.
**Files**: `build.gradle.kts`, `config/dependency-check-suppression.xml`, `.github/workflows/security-scan.yml`, `chronicle-web/package.json`

#### Gradle: OWASP Dependency-Check
- Scans all subprojects (rhizome, rhizome-client, chronicle-api, chronicle-server)
- Fails build on CVSS >= 7.0 (high/critical vulnerabilities)
- Generates HTML, JSON, and SARIF reports
- NVD data cached locally for faster subsequent runs

#### NPM: npm audit
- Scans chronicle-web dependencies
- Fails CI on high/critical vulnerabilities
- Scripts: `npm run audit`, `npm run audit:ci`, `npm run audit:fix`

#### CI Integration
- Runs on every push/PR to develop and main
- Weekly scheduled scans (Sundays at 2 AM UTC)
- SARIF reports uploaded to GitHub Security tab
- Artifacts retained for 30 days

#### Suppressing False Positives
Add documented suppressions to `config/dependency-check-suppression.xml`:
```xml
<suppress until="2025-12-31">
    <notes><![CDATA[
        CVE-2024-XXXX: Description
        Reason: Explain why this is a false positive
        Reviewed by: Name, Date
    ]]></notes>
    <gav regex="true">^com\.example:library:.*$</gav>
    <vulnerabilityName>CVE-2024-XXXX</vulnerabilityName>
</suppress>
```

### Jackson Serialization Hardening
**What**: Security-hardened Jackson ObjectMapper configuration that prevents deserialization attacks.
**Why**: Jackson's default typing feature allows attackers to specify arbitrary class types in JSON payloads, enabling Remote Code Execution (RCE) via gadget chains (CVE-2017-7525 and related).
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/JacksonSecurityConfig.kt`

#### Protections Implemented

| Setting | Value | Purpose |
|---------|-------|---------|
| Default Typing | DISABLED | Prevents polymorphic deserialization RCE attacks |
| FAIL_ON_UNKNOWN_PROPERTIES | true | Prevents mass assignment attacks |
| FAIL_ON_NULL_FOR_PRIMITIVES | true | Rejects null values for primitive types |
| FAIL_ON_NUMBERS_FOR_ENUMS | true | Prevents numeric enum value injection |
| FAIL_ON_NULL_CREATOR_PROPERTIES | true | Rejects null in constructor properties |

#### Verification

```bash
# Test that @type field is rejected (should return 400 Bad Request)
curl -X POST http://localhost:8080/api/endpoint \
  -H "Content-Type: application/json" \
  -d '{"@type": "java.lang.Runtime", "data": "malicious"}'

# Test unknown fields are rejected (should return 400 Bad Request)
curl -X POST http://localhost:8080/api/endpoint \
  -H "Content-Type: application/json" \
  -d '{"validField": "value", "unknownField": "attack"}'
```

#### CVEs Mitigated
- CVE-2017-7525 - Jackson Databind deserialization RCE
- CVE-2017-15095 - Jackson Databind deserialization via c3p0
- CVE-2018-5968 - Jackson Databind deserialization via JNDI
- CVE-2019-12086 - Jackson Databind "Polymorphic Typing" RCE
- CVE-2020-8840 - Jackson Databind default typing RCE
- And numerous related deserialization vulnerabilities

### Spring Security Request Hardening
**What**: Security filters that block dangerous HTTP requests and add defense-in-depth headers.
**Why**: Prevents HTTP TRACE attacks (XST), null byte injection, and provides backup security headers at the application level.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SecurityHardeningConfig.kt`

#### Protections Implemented

| Filter | Purpose | Response |
|--------|---------|----------|
| TRACE Method Blocking | Prevents Cross-Site Tracing (XST) attacks | 405 Method Not Allowed |
| Null Byte Validation | Blocks path traversal attacks | 400 Bad Request |
| Parameter Length Limits | Prevents buffer overflow | 400 Bad Request |
| Request Size Limits | Prevents memory exhaustion DoS | 413 Payload Too Large |

#### Security Headers Added (Defense-in-Depth)

These headers are added at the application level as backup to nginx/load balancer headers:

| Header | Value | Purpose |
|--------|-------|---------|
| X-Content-Type-Options | nosniff | Prevent MIME type sniffing |
| X-Frame-Options | DENY | Prevent clickjacking |
| X-XSS-Protection | 1; mode=block | Enable browser XSS filter |
| Cache-Control | no-cache, no-store, must-revalidate | Prevent sensitive data caching |
| Referrer-Policy | strict-origin-when-cross-origin | Limit referrer information leakage |
| Permissions-Policy | Restrictive | Disable unused browser features |

#### Verification

```bash
# Test HTTP TRACE is blocked (should return 405)
curl -X TRACE http://localhost:8080/api/endpoint

# Test null byte rejection (should return 400)
curl "http://localhost:8080/api/endpoint?param=test%00attack"

# Test request size limit (should return 413 for >10MB)
dd if=/dev/zero bs=1M count=15 2>/dev/null | curl -X POST -d @- http://localhost:8080/api/test
```

#### Configuration

Adjust limits in `SecurityHardeningConfig.kt`:

```kotlin
companion object {
    const val MAX_REQUEST_SIZE_BYTES: Long = 10 * 1024 * 1024  // 10MB
    const val MAX_PARAMETER_LENGTH: Int = 10000
}
```

### Constant-Time Secret Comparison
**What**: Utility for comparing secrets (API keys, tokens) in constant time to prevent timing attacks.
**Why**: Standard string comparison (equals, ==) returns early on the first mismatched character. Attackers can measure response times to determine how many characters match, enabling character-by-character brute force of secrets.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/SecureCompare.kt`

#### How It Works

The `SecureCompare` utility uses `MessageDigest.isEqual()` which is guaranteed to perform constant-time comparison regardless of:
- How many characters match
- Where the first mismatch occurs
- The length of the strings

#### Usage

```kotlin
import com.openlattice.chronicle.util.SecureCompare

// For API key validation
if (SecureCompare.equals(providedApiKey, storedApiKey)) {
    // Authenticated
}

// For token validation
if (SecureCompare.validateToken(providedToken, expectedToken)) {
    // Valid token
}

// Null-safe comparison
if (SecureCompare.equalsNullSafe(maybeNullKey, storedKey)) {
    // Authenticated
}
```

#### Methods Available

| Method | Purpose |
|--------|---------|
| `equals(a: String, b: String)` | Constant-time string comparison |
| `equalsNullSafe(a: String?, b: String?)` | Null-safe string comparison |
| `equals(a: ByteArray, b: ByteArray)` | Constant-time byte array comparison |
| `validateApiKey(provided, stored)` | Convenience method for API key validation |
| `validateToken(provided, expected)` | Convenience method for token validation |

#### Security Rationale

Timing attacks work because:
1. String `equals()` returns `false` as soon as it finds a mismatching character
2. A comparison of "AAAA" vs "BAAA" takes less time than "AAAA" vs "AAAB"
3. Attackers measure response times to deduce how many characters match
4. With enough requests, they can brute-force the secret character by character

`MessageDigest.isEqual()` always compares all bytes, taking constant time regardless of where or if strings differ.

### Open Redirect Prevention
**What**: Filter that validates all redirect URLs to prevent open redirect attacks.
**Why**: Open redirects allow attackers to craft URLs that appear to originate from your trusted domain but redirect users to phishing sites. Example: `https://trusted.com/login?redirect=https://evil.com/phishing`
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/RedirectValidator.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/OpenRedirectFilter.kt`

#### Attack Vectors Prevented

| Attack Vector | Protection |
|---------------|------------|
| External domain redirect | Only whitelisted domains allowed |
| Protocol-relative URL (`//evil.com`) | Blocked by pattern detection |
| JavaScript/data: URLs | Blocked - only http/https allowed |
| URL with credentials (`user@evil.com`) | Blocked by pattern detection |
| Header injection via newlines | Blocked - CR/LF characters rejected |
| Null byte injection | Blocked by pattern detection |
| URL encoding bypass (`%2f%2f`) | Blocked by pattern detection |

#### Configuration

Configure allowed redirect domains in `application.yaml`:

```yaml
chronicle:
  security:
    redirect:
      allowed-domains: methodic.us.auth0.com,auth0.com
      fallback-url: /
      strict-host-matching: true
```

| Setting | Default | Purpose |
|---------|---------|---------|
| `allowed-domains` | `methodic.us.auth0.com` | Comma-separated list of allowed external domains |
| `fallback-url` | `/` | URL to redirect to when an invalid redirect is blocked |
| `strict-host-matching` | `true` | When false, subdomains of allowed domains are permitted |

#### How It Works

1. **Filter Layer**: `OpenRedirectFilter` wraps all HTTP responses to intercept `sendRedirect()` calls
2. **Validation**: Each redirect URL is validated by `RedirectValidator`
3. **Safe Redirects Allowed**:
   - Relative paths starting with `/` (e.g., `/dashboard`)
   - Same-origin absolute URLs
   - URLs to explicitly whitelisted domains
4. **Blocked Redirects**: Replaced with fallback URL and logged as security warning

#### Verification

```bash
# Test that same-origin redirect works
curl -v -L "http://localhost:8080/login?redirect=/dashboard"
# Should redirect to /dashboard

# Test that external domain redirect is blocked
curl -v -L "http://localhost:8080/login?redirect=https://evil.com/phishing"
# Should redirect to / (fallback)

# Test that javascript: URL is blocked
curl -v -L "http://localhost:8080/login?redirect=javascript:alert(1)"
# Should redirect to / (fallback)

# Test that data: URL is blocked
curl -v -L "http://localhost:8080/login?redirect=data:text/html,<script>alert(1)</script>"
# Should redirect to / (fallback)

# Test that protocol-relative URL is blocked
curl -v -L "http://localhost:8080/login?redirect=//evil.com/path"
# Should redirect to / (fallback)

# Check logs for blocked redirect attempts
grep "Blocked open redirect" /var/log/chronicle/server.log
```

#### Usage in Controllers

```kotlin
@RestController
class LoginController(
    private val redirectValidator: RedirectValidator
) {
    @GetMapping("/callback")
    fun callback(
        @RequestParam("redirect", required = false) redirectUrl: String?,
        request: HttpServletRequest,
        response: HttpServletResponse
    ) {
        // Safe redirect - validates and falls back to /dashboard if invalid
        val safeUrl = redirectValidator.getSafeRedirectUrl(
            request,
            redirectUrl,
            fallback = "/dashboard"
        )
        response.sendRedirect(safeUrl)
    }
}
```

### Log Injection Sanitization
**What**: Utility to sanitize user input before writing to log files, preventing log injection attacks.
**Why**: Attackers can inject fake log entries by including newlines/carriage returns in input, hiding malicious activity or confusing forensics.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/LogSanitizer.kt`

#### Attack Vectors Prevented

| Attack | Technique | Mitigation |
|--------|-----------|------------|
| Log Forging | Inject newlines to create fake log entries | Escape `\n`, `\r`, `\r\n` |
| Log Pollution | Inject massive text to hide activity | Truncate long strings |
| Terminal Exploitation | ANSI escape sequences | Strip escape sequences |
| Log Analysis Bypass | Control characters to corrupt parsing | Replace with hex notation |

#### Usage Examples

```kotlin
import com.openlattice.chronicle.util.LogSanitizer

// Basic sanitization
logger.info("User input: ${LogSanitizer.sanitize(userInput)}")

// With custom max length
logger.warn("Parameter: ${LogSanitizer.sanitize(param, maxLength = 100)}")

// Quoted for clarity
logger.debug("Value: ${LogSanitizer.sanitizeQuoted(value)}")

// Sanitize collections
logger.info("IDs: ${LogSanitizer.sanitizeCollection(ids)}")

// Sanitize maps (e.g., request parameters)
logger.info("Params: ${LogSanitizer.sanitizeMap(request.parameterMap)}")

// Sanitize IP addresses
logger.info("Client IP: ${LogSanitizer.sanitizeIp(request.remoteAddr)}")

// Sanitize URIs
logger.info("Request URI: ${LogSanitizer.sanitizeUri(request.requestURI)}")
```

#### Verification

```bash
# Test log injection attempt
curl "http://localhost:8080/api/test?input=normal%0AERROR%20Fake%20error%20message"
# Check logs - should show escaped newline: "normal\nERROR Fake error message"

# Test ANSI escape injection
curl "http://localhost:8080/api/test?input=%1B%5B31mRED%1B%5B0m"
# Check logs - should show: "[ESC]RED[ESC]" not colored text

# Test length truncation
curl "http://localhost:8080/api/test?input=$(python3 -c 'print("A"*2000)')"
# Check logs - should be truncated with "...[truncated]"
```

### XXE (XML External Entity) Prevention
**What**: Secure XML parser factory that disables external entities, DTD processing, and other XXE attack vectors.
**Why**: XML parsers with default settings can be exploited to read arbitrary files, perform SSRF, or cause DoS via entity expansion.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/SecureXmlFactory.kt`

#### Attack Vectors Prevented

| Attack | Technique | Impact | Mitigation |
|--------|-----------|--------|------------|
| File Disclosure | `<!ENTITY xxe SYSTEM "file:///etc/passwd">` | Read sensitive files | Disable external entities |
| SSRF | `<!ENTITY xxe SYSTEM "http://internal-server/">` | Access internal services | Disable external entities |
| DoS (Billion Laughs) | Exponential entity expansion | Memory exhaustion | Disable DTD processing |
| Parameter Entity Attack | `%xxe;` in DTD | Exfiltration, RCE | Disable parameter entities |

#### Usage Examples

```kotlin
import com.openlattice.chronicle.util.SecureXmlFactory

// Parse XML string safely
val document = SecureXmlFactory.parseDocument(xmlString)

// Parse from InputStream
val document = SecureXmlFactory.parseDocument(inputStream)

// Use StAX reader
val reader = SecureXmlFactory.createXmlStreamReader(inputStream)

// Create secure DocumentBuilder for custom parsing
val builder = SecureXmlFactory.createDocumentBuilder()

// Preliminary validation (fast, before full parsing)
SecureXmlFactory.validateXmlSecurity(xmlString)

// Defense-in-depth: validate + parse
val document = SecureXmlFactory.safeParseDocument(xmlString)
```

#### Verification

```bash
# Test XXE file read attack (should fail)
curl -X POST http://localhost:8080/api/xml-endpoint \
  -H "Content-Type: application/xml" \
  -d '<?xml version="1.0"?>
<!DOCTYPE foo [
  <!ENTITY xxe SYSTEM "file:///etc/passwd">
]>
<data>&xxe;</data>'
# Expected: 400 Bad Request - "DOCTYPE declarations are not allowed"

# Test entity expansion attack (should fail)
curl -X POST http://localhost:8080/api/xml-endpoint \
  -H "Content-Type: application/xml" \
  -d '<?xml version="1.0"?>
<!DOCTYPE lolz [
  <!ENTITY lol "lol">
  <!ENTITY lol2 "&lol;&lol;&lol;">
]>
<data>&lol2;</data>'
# Expected: 400 Bad Request

# Test valid XML (should succeed)
curl -X POST http://localhost:8080/api/xml-endpoint \
  -H "Content-Type: application/xml" \
  -d '<?xml version="1.0"?><data>valid content</data>'
# Expected: 200 OK
```

#### CVEs Mitigated
- CWE-611: Improper Restriction of XML External Entity Reference
- CWE-776: Improper Restriction of Recursive Entity References in DTDs
- CVE-2014-3529: Apache POI XXE vulnerability pattern
- Various library-specific XXE CVEs

### HTTP Parameter Pollution (HPP) Prevention
**What**: Filter that detects and rejects requests with duplicate parameter names.
**Why**: Different frameworks handle duplicate parameters differently, enabling validation bypass and logic errors.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/ParameterPollutionFilter.kt`

#### Attack Scenarios

| Scenario | Attack | Impact |
|----------|--------|--------|
| Validation Bypass | `?amount=100&amount=1000000` | First validated (100), second used (1000000) |
| WAF Bypass | `?cmd=safe&cmd=malicious` | WAF checks first, app uses last |
| SQL Injection | `?id=1&id=1 OR 1=1` | Bypass input sanitization |
| Authentication Bypass | `?admin=false&admin=true` | Override authorization checks |

#### Configuration

```kotlin
// Whitelist parameters that legitimately need multiple values
val ALLOWED_DUPLICATE_PARAMS: Set<String> = setOf(
    "ids",         // API endpoints accepting multiple IDs
    "tags",        // Multi-select tag filters
    "categories",  // Multi-category filtering
    "fields",      // Field selection
    "sort",        // Multiple sort criteria
    "filter",      // Multiple filters
    "include",     // Include multiple relations
    "exclude",     // Exclude multiple items
    "select",      // Field selection
    "expand"       // OData expansion
)

// Maximum values even for whitelisted parameters
const val MAX_ALLOWED_DUPLICATES: Int = 100
```

#### Verification

```bash
# Test duplicate parameter rejection (should return 400)
curl "http://localhost:8080/api/endpoint?userId=123&userId=456"
# Expected: 400 Bad Request - "Duplicate parameter not allowed: userId"

# Test whitelisted parameter (should succeed)
curl "http://localhost:8080/api/endpoint?ids=123&ids=456"
# Expected: 200 OK (ids is whitelisted)

# Test array notation (should succeed)
curl "http://localhost:8080/api/endpoint?items[]=1&items[]=2"
# Expected: 200 OK (array notation allowed)

# Test excessive duplicates (should return 400)
curl "http://localhost:8080/api/endpoint?ids=$(seq -s '&ids=' 1 150)"
# Expected: 400 Bad Request - "Too many values for parameter: ids"

# Test normal request (should succeed)
curl "http://localhost:8080/api/endpoint?userId=123&name=test"
# Expected: 200 OK
```

#### Filter Order

The parameter pollution filter runs at priority `Ordered.HIGHEST_PRECEDENCE + 5`:
1. TRACE method blocking (HIGHEST_PRECEDENCE)
2. Security headers (HIGHEST_PRECEDENCE + 1)
3. Request validation/null bytes (HIGHEST_PRECEDENCE + 2)
4. Request size limits (HIGHEST_PRECEDENCE + 3)
5. Parameter pollution filter (HIGHEST_PRECEDENCE + 5)
6. Mobile API signature filter (HIGHEST_PRECEDENCE + 10)

### Mobile API HMAC Request Signing and Replay Prevention
**What**: HMAC-SHA256 request signing with timestamp validation and nonce-based replay prevention for mobile API endpoints.
**Why**: Prevents request tampering (MITM attacks) and replay attacks on `/api/mobile/*` endpoints that handle sensitive data from mobile clients.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/MobileApiSignatureFilter.kt`, `CachedBodyHttpServletRequest.kt`, `MobileApiSecurityConfig.kt`

For detailed documentation, see [MOBILE-API-SECURITY.md](./MOBILE-API-SECURITY.md).

#### Protections Implemented (Mobile API)

| Protection | Mechanism | Configuration |
|------------|-----------|---------------|
| Request Tampering | HMAC-SHA256 signature of method+path+timestamp+nonce+body | Constant-time comparison |
| Replay Attacks | Timestamp validation (5 min max age) | `max-request-age-minutes: 5` |
| Clock Skew | 30 second tolerance | `clock-skew-seconds: 30` |
| Nonce Replay | Hazelcast distributed nonce cache | `nonce-ttl-minutes: 10` |
| Timing Attacks | `MessageDigest.isEqual()` for comparison | Built-in |

#### Required Headers

| Header | Description | Example |
|--------|-------------|---------|
| `X-Chronicle-Signature` | Base64 HMAC-SHA256 | `a3f2b7c8d9e0f1...` |
| `X-Chronicle-Timestamp` | Unix epoch seconds | `1704067200` |
| `X-Chronicle-Nonce` | UUID | `550e8400-e29b-41d4-...` |

#### Configuration

```yaml
# mobile-security.yaml
enabled: true
signing-secret: "your-256-bit-secret-key-here"
signing-required: false  # Set true to enforce signing
max-request-age-minutes: 5
clock-skew-seconds: 30
nonce-ttl-minutes: 10
```

#### Deployment Strategy

1. **Phase 1 (Monitor)**: `signing-required: false` - Unsigned requests allowed, warnings logged
2. **Phase 2 (Enforce)**: `signing-required: true` - All requests must be signed

#### Verification

```bash
# Generate test signature
TIMESTAMP=$(date +%s)
NONCE=$(uuidgen)
BODY='{"data": "test"}'
BODY_HASH=$(echo -n "$BODY" | sha256sum | cut -d' ' -f1)
SIGNING_STRING="POST|/api/mobile/test|$TIMESTAMP|$NONCE|$BODY_HASH"
SIGNATURE=$(echo -n "$SIGNING_STRING" | openssl dgst -sha256 -hmac "your-secret" -binary | base64)

curl -X POST http://localhost:8081/api/mobile/test \
  -H "Content-Type: application/json" \
  -H "X-Chronicle-Signature: $SIGNATURE" \
  -H "X-Chronicle-Timestamp: $TIMESTAMP" \
  -H "X-Chronicle-Nonce: $NONCE" \
  -d "$BODY"
```

### CORS (Cross-Origin Resource Sharing) Security
**What**: Strict CORS configuration to prevent unauthorized cross-origin requests while allowing legitimate frontend access.
**Why**: Without proper CORS configuration, malicious websites could make cross-origin requests to the Chronicle API, potentially stealing data or performing actions on behalf of authenticated users. CORS is a critical browser security mechanism that must be configured correctly.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/CorsConfig.kt`, `CorsSecurityConfig.kt`, `CorsValidationFilter.kt`, `CookieConfig.kt`, `chronicle-server/src/main/resources/cors.yaml`

#### Attack Vectors Prevented

| Attack Vector | Description | Protection |
|---------------|-------------|------------|
| Unauthorized Cross-Origin Requests | Malicious sites making API calls | Origin allowlist validation |
| Credential Theft | Stealing cookies via cross-origin requests | Credentials only for trusted origins |
| CSRF via CORS | Using CORS to bypass CSRF protections | Strict origin validation |
| Null Origin Attacks | Sandboxed iframes/data: URLs accessing API | Explicit "null" origin blocking |
| Wildcard with Credentials | Insecure `*` origin with credentials | Configuration validation |
| HTTP Methods Abuse | TRACE/TRACK used for XST attacks | Method allowlist |

#### Configuration

Configure CORS in `cors.yaml`:

```yaml
# cors.yaml
enabled: true

# Strict origin allowlist - no wildcards
allowed-origins:
  - "https://app.methodic.io"
  - "https://chronicle.openlattice.com"
  - "https://methodic.io"

# Only necessary HTTP methods (TRACE/TRACK automatically filtered)
allowed-methods:
  - "GET"
  - "POST"
  - "PUT"
  - "DELETE"
  - "PATCH"
  - "OPTIONS"

# Whitelisted request headers
allowed-headers:
  - "Authorization"
  - "Content-Type"
  - "Accept"
  - "X-Requested-With"
  - "Origin"
  - "X-Chronicle-Signature"
  - "X-Chronicle-Timestamp"
  - "X-Chronicle-Nonce"

# Limited response header exposure
exposed-headers:
  - "X-Request-Id"
  - "X-RateLimit-Limit"
  - "X-RateLimit-Remaining"
  - "X-RateLimit-Reset"

# Credentials require explicit origin (no wildcards)
allow-credentials: true

# Preflight caching (1 hour)
max-age-seconds: 3600

# Development mode adds localhost origins automatically
development-mode: false

# Localhost ports for development (only when development-mode: true)
development-ports:
  - 3000
  - 3001
  - 5173
  - 8080
```

| Setting | Default | Purpose |
|---------|---------|---------|
| `enabled` | `true` | Enable/disable CORS handling |
| `allowed-origins` | `[]` | Explicit list of allowed origins (no wildcards with credentials) |
| `allowed-methods` | Standard methods | HTTP methods allowed for cross-origin requests |
| `allowed-headers` | Auth/content headers | Request headers frontend can send |
| `exposed-headers` | Rate limit headers | Response headers JavaScript can read |
| `allow-credentials` | `true` | Allow cookies/auth headers (requires explicit origins) |
| `max-age-seconds` | `3600` | Preflight cache duration (1 hour) |
| `development-mode` | `false` | Auto-add localhost origins for development |

#### Cookie Security (SameSite)

Cookie security is configured via environment properties:

```yaml
# Chronicle cookie security settings
chronicle:
  security:
    cookie:
      same-site: Lax     # Lax, Strict, or None
      secure: true       # Only send over HTTPS
      http-only: true    # No JavaScript access
      path: /            # Cookie path
      max-age: -1        # Session cookie (-1) or seconds
```

| SameSite Value | Behavior | Use Case |
|----------------|----------|----------|
| `Strict` | Cookie only sent with same-site requests | Maximum security, may break OAuth flows |
| `Lax` | Cookie sent with same-site + top-level navigations | Default, good balance |
| `None` | Cookie sent with all requests (requires Secure) | Cross-origin authenticated requests |

#### Defense-in-Depth Layers

CORS protection is implemented at multiple levels:

1. **CorsSecurityConfig**: Spring Security CORS integration for consistent preflight handling
2. **CorsValidationFilter**: Defense-in-depth origin validation (runs before Spring Security)
3. **CookieConfig**: SameSite cookie attributes for CSRF protection
4. **Configuration Validation**: Warns about insecure configurations (e.g., `*` with credentials)

#### Filter Priority

The CORS validation filter runs at priority `Ordered.HIGHEST_PRECEDENCE + 4`:
1. TRACE method blocking (HIGHEST_PRECEDENCE)
2. Security headers (HIGHEST_PRECEDENCE + 1)
3. Request validation/null bytes (HIGHEST_PRECEDENCE + 2)
4. Request size limits (HIGHEST_PRECEDENCE + 3)
5. **CORS validation filter (HIGHEST_PRECEDENCE + 4)**
6. Parameter pollution filter (HIGHEST_PRECEDENCE + 5)
7. Cookie security filter (HIGHEST_PRECEDENCE + 6)
8. Mobile API signature filter (HIGHEST_PRECEDENCE + 10)

#### Verification

```bash
# Test that allowed origin succeeds (should get CORS headers)
curl -v -H "Origin: https://app.methodic.io" \
     -X GET http://localhost:8081/chronicle/healthcheck
# Expected: Access-Control-Allow-Origin: https://app.methodic.io

# Test preflight request (OPTIONS)
curl -v -X OPTIONS \
     -H "Origin: https://app.methodic.io" \
     -H "Access-Control-Request-Method: POST" \
     -H "Access-Control-Request-Headers: Content-Type,Authorization" \
     http://localhost:8081/chronicle/v3/study
# Expected: 200 with CORS headers, Access-Control-Max-Age: 3600

# Test disallowed origin returns 403 Forbidden
curl -v -H "Origin: https://evil.com" \
     -X GET http://localhost:8081/chronicle/healthcheck
# Expected: 403 Forbidden

# Test null origin is blocked
curl -v -H "Origin: null" \
     -X GET http://localhost:8081/chronicle/healthcheck
# Expected: 403 Forbidden

# Test that TRACE method is blocked (regardless of origin)
curl -v -X TRACE http://localhost:8081/chronicle/healthcheck
# Expected: 405 Method Not Allowed

# Verify SameSite cookie attribute
curl -v -c cookies.txt http://localhost:8081/some-endpoint-that-sets-cookie
cat cookies.txt
# Expected: Cookie with SameSite=Lax (or configured value)

# Check CORS configuration in logs
grep "CORS configuration initialized" /var/log/chronicle/server.log
```

#### Browser DevTools Verification

1. Open Chrome DevTools (F12) > Network tab
2. Make a cross-origin request to the API from your frontend
3. Check the Response Headers for:
   - `Access-Control-Allow-Origin`: Should be your frontend origin (not `*`)
   - `Access-Control-Allow-Credentials`: Should be `true`
   - `Access-Control-Allow-Methods`: Should list allowed methods
   - `Access-Control-Expose-Headers`: Should list exposed headers
   - `Access-Control-Max-Age`: Should be 3600 (1 hour)
4. For preflight requests (OPTIONS), verify they complete successfully
5. If credentials are sent, verify `Access-Control-Allow-Origin` is NOT `*`

#### Environment-Specific Configuration

| Environment | development-mode | allowed-origins |
|-------------|------------------|-----------------|
| Local | `true` | Production + localhost:3000, 3001, 5173, 8080 |
| Staging | `false` | Staging domains only |
| Production | `false` | Production domains only (HTTPS) |

**Development**: Copy `cors-local.yaml` to `cors.yaml` or configure `development-mode: true`

**Production**: Ensure `development-mode: false` and only list production HTTPS origins

### Distributed Rate Limiting (Bucket4j + Hazelcast)
**What**: Token bucket rate limiting distributed across all cluster nodes using Bucket4j with Hazelcast backend.
**Why**: Protects against brute force attacks, DoS from individual clients, and API abuse. Distributed state ensures consistent limiting regardless of which node receives requests.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/RateLimitConfig.kt`, `RateLimitFilter.kt`, `RateLimitConfiguration.kt`, `RateLimit.kt`

#### Attack Scenarios Prevented

| Attack | Rate Limit Applied | Default Limit |
|--------|-------------------|---------------|
| Brute Force Login | Authentication endpoints | 5 req/min per IP |
| API Abuse | General endpoints | 100 req/min per IP/user |
| DoS from Single Client | All endpoints | Configurable limits |
| Credential Stuffing | Auth endpoints | 5 req/min per IP |
| Resource Exhaustion | Sensitive operations | 20 req/min per IP/user |

#### Configuration

Configure rate limiting in `rate-limit.yaml`:

```yaml
# rate-limit.yaml
enabled: true

# Default rate limits
default-requests-per-minute: 100
auth-requests-per-minute: 5
sensitive-requests-per-minute: 20
burst-capacity-multiplier: 1.5

# Whitelisted IPs (bypass rate limiting)
whitelisted-ips:
  - "127.0.0.1"
  - "::1"
  - "10.0.0.0/8"      # Internal network
  - "172.16.0.0/12"   # Docker networks
  - "192.168.0.0/16"  # Private networks

# Whitelisted paths (bypass rate limiting)
whitelisted-paths:
  - "/healthcheck"
  - "/actuator/health"
  - "/actuator/prometheus"

# Authentication endpoint patterns (stricter limits)
auth-paths:
  - "/auth/"
  - "/login"
  - "/oauth/"
  - "/api/auth/"

# Client IP extraction
client-ip-header: "X-Forwarded-For"
client-ip-header-fallback: "X-Real-IP"
trust-proxy-headers: true

# Hazelcast configuration
hazelcast-map-name: "RATE_LIMIT_BUCKETS"
entry-ttl-seconds: 120

# Response headers
include-headers: true
include-retry-after: true
```

#### Rate Limit Types

| Type | Default Rate | Use Case |
|------|--------------|----------|
| DEFAULT | 100 req/min | General API endpoints |
| AUTH | 5 req/min | Login, password reset, OAuth |
| SENSITIVE | 20 req/min | Data export, bulk operations |
| UNLIMITED | No limit | Internal/admin endpoints (bypass=true) |

#### Key Strategies

| Strategy | Description | Use Case |
|----------|-------------|----------|
| AUTO | User ID if authenticated, IP otherwise | Default for most endpoints |
| IP | Always use client IP | Public endpoints |
| USER | Always use user ID | User-specific limits |
| USER_AND_IP | Combination of user + IP | Per-user-per-device limits |
| ENDPOINT | Path + user/IP | Per-endpoint limits |

#### @RateLimit Annotation Usage

```kotlin
@RestController
@RateLimit(requestsPerMinute = 50)  // Controller-level default
class MyController {

    @GetMapping("/fast")
    @RateLimit(requestsPerMinute = 200)  // Override for this endpoint
    fun fastEndpoint(): Response { ... }

    @PostMapping("/login")
    @RateLimit(type = RateLimitType.AUTH)  // Use auth rate (5 req/min)
    fun login(): Response { ... }

    @PostMapping("/export")
    @RateLimit(type = RateLimitType.SENSITIVE)  // Use sensitive rate (20 req/min)
    fun exportData(): Response { ... }

    @GetMapping("/internal")
    @RateLimit(bypass = true)  // No rate limiting
    fun internalEndpoint(): Response { ... }

    @GetMapping("/user-specific")
    @RateLimit(keyStrategy = RateLimitKeyStrategy.USER)  // Rate per user
    fun userSpecificEndpoint(): Response { ... }
}
```

#### Response Headers

When rate limiting is active, responses include:

| Header | Description | Example |
|--------|-------------|---------|
| `X-RateLimit-Limit` | Maximum requests per minute | `100` |
| `X-RateLimit-Remaining` | Remaining requests in window | `75` |
| `X-RateLimit-Reset` | Unix timestamp when limit resets | `1704067200` |
| `Retry-After` | Seconds to wait (only on 429) | `45` |

#### 429 Response Format

```json
{
    "error": "Rate limit exceeded",
    "status": 429,
    "retryAfter": 45,
    "message": "Too many requests. Please wait 45 seconds before retrying."
}
```

#### How It Works

1. **Token Bucket Algorithm**: Each client gets a bucket that fills at a steady rate (tokens/minute). Each request consumes one token. When empty, requests are rejected.

2. **Distributed State**: Bucket state is stored in Hazelcast IMap, shared across all cluster nodes. A request hitting any node sees the same rate limit state.

3. **Key Generation**: Rate limit keys are generated based on the key strategy (AUTO by default):
   - Authenticated users: `rl:user:{userId}`
   - Unauthenticated: `rl:ip:{clientIp}`

4. **Burst Handling**: Burst capacity (default 1.5x) allows temporary spikes while maintaining long-term rate limits.

#### Filter Priority

The rate limit filter runs at priority `Ordered.HIGHEST_PRECEDENCE + 20`:
1. TRACE method blocking (HIGHEST_PRECEDENCE)
2. Security headers (HIGHEST_PRECEDENCE + 1)
3. Request validation (HIGHEST_PRECEDENCE + 2)
4. Request size limits (HIGHEST_PRECEDENCE + 3)
5. Parameter pollution filter (HIGHEST_PRECEDENCE + 5)
6. Mobile API signature filter (HIGHEST_PRECEDENCE + 10)
7. **Rate limit filter (HIGHEST_PRECEDENCE + 20)**
8. Spring Security authentication

#### Verification

```bash
# Test normal request (should succeed with rate limit headers)
curl -v http://localhost:8081/api/endpoint
# Check for X-RateLimit-* headers in response

# Test rate limiting (send many requests quickly)
for i in {1..150}; do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/api/endpoint
done
# Should see 200s followed by 429s

# Test authentication endpoint (stricter limit)
for i in {1..10}; do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/auth/login
done
# Should see 429 after ~5 requests

# Test whitelisted path (no rate limiting)
for i in {1..200}; do
  curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/healthcheck
done
# All requests should succeed (200)

# Check rate limit headers
curl -I http://localhost:8081/api/endpoint 2>/dev/null | grep -i "x-ratelimit"
# Expected:
# X-RateLimit-Limit: 100
# X-RateLimit-Remaining: 99
# X-RateLimit-Reset: 1704067260

# Check Hazelcast map for rate limit state
# (via Hazelcast Management Center or logs)
```

#### Hazelcast Configuration

The rate limit filter automatically configures a Hazelcast IMap with:
- **TTL**: 120 seconds (configurable)
- **Backup count**: 1 (for high availability)
- **Statistics**: Disabled (for performance)

#### CVEs Mitigated

- CWE-307: Improper Restriction of Excessive Authentication Attempts
- CWE-799: Improper Control of Interaction Frequency
- OWASP API4:2023 - Unrestricted Resource Consumption
- Brute force attacks (OWASP Testing Guide)
- Credential stuffing attacks

### SSRF (Server-Side Request Forgery) Prevention
**What**: Comprehensive protection against SSRF attacks for all outbound HTTP requests.
**Why**: Without URL validation, attackers could trick the server into making requests to internal services, cloud metadata endpoints, localhost, or private IP ranges. SSRF can lead to data exfiltration, internal service compromise, and cloud credential theft.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SsrfConfig.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/SsrfValidator.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SafeHttpClientFactory.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/util/SsrfException.kt`

#### Attack Vectors Prevented

| Attack Vector | Description | Protection |
|---------------|-------------|------------|
| Internal Service Access | Accessing internal APIs via server | Host allowlist validation |
| Cloud Metadata Theft | Accessing 169.254.169.254 for cloud credentials | Metadata IP blocking |
| Localhost Access | Accessing localhost services | Loopback address blocking |
| Private Network Scan | Scanning internal networks via server | Private IP range blocking |
| DNS Rebinding | DNS changing to internal IP after validation | Pre-connection IP validation |
| Protocol Smuggling | Using file://, gopher://, ftp:// | Protocol allowlist (HTTPS only) |
| Redirect Bypass | Redirecting to blocked destinations | Redirect destination validation |
| Excessive Redirects | DoS via redirect loops | Maximum redirect limit (3) |

#### Configuration

Configure SSRF protection in `ssrf.yaml`:

```yaml
# ssrf.yaml
enabled: true

# Allowed hosts for outbound requests (default: Auth0 domains)
allowedHosts:
  - methodic.us.auth0.com
  - auth0.com
  - cdn.auth0.com

# Allowed protocols (default: HTTPS only)
allowedProtocols:
  - https

# IP blocking configuration
blockPrivateIps: true        # Block 10.x, 172.16-31.x, 192.168.x
blockLocalhost: true         # Block 127.0.0.1, ::1
blockLinkLocal: true         # Block 169.254.x.x, fe80::
blockMetadataEndpoints: true # Block 169.254.169.254 (cloud metadata)

# Redirect handling
validateRedirects: true      # Validate redirect destinations
maxRedirects: 3              # Maximum redirects to follow
```

| Setting | Default | Purpose |
|---------|---------|---------|
| `enabled` | `true` | Master switch for SSRF protection |
| `allowedHosts` | Auth0 domains | Explicit allowlist of permitted hosts |
| `allowedProtocols` | `https` | Only HTTPS by default |
| `blockPrivateIps` | `true` | Block RFC 1918 private IP ranges |
| `blockLocalhost` | `true` | Block loopback addresses |
| `blockLinkLocal` | `true` | Block link-local addresses |
| `blockMetadataEndpoints` | `true` | Block cloud metadata IPs (AWS, GCP, Azure) |
| `validateRedirects` | `true` | Validate HTTP redirect destinations |
| `maxRedirects` | `3` | Maximum redirect chain length |

#### Private IP Ranges Blocked

| Range | CIDR | Description |
|-------|------|-------------|
| 10.0.0.0 - 10.255.255.255 | 10.0.0.0/8 | Class A private network |
| 172.16.0.0 - 172.31.255.255 | 172.16.0.0/12 | Class B private network |
| 192.168.0.0 - 192.168.255.255 | 192.168.0.0/16 | Class C private network |
| 127.0.0.0 - 127.255.255.255 | 127.0.0.0/8 | Loopback |
| 169.254.0.0 - 169.254.255.255 | 169.254.0.0/16 | Link-local |
| fc00::/7 | fc00::/7 | IPv6 unique local addresses |
| ::1 | ::1/128 | IPv6 loopback |
| fe80::/10 | fe80::/10 | IPv6 link-local |

#### Cloud Metadata Endpoints Blocked

| IP/Hostname | Cloud Provider |
|-------------|----------------|
| 169.254.169.254 | AWS, GCP, Azure |
| 100.100.100.200 | Alibaba Cloud |
| 192.0.0.192 | Oracle Cloud |
| fd00:ec2::254 | AWS IPv6 |
| metadata.google.internal | GCP |
| instance-data | AWS |

#### Usage Examples

```kotlin
import com.openlattice.chronicle.configuration.SafeHttpClientFactory
import com.openlattice.chronicle.configuration.SsrfConfig
import com.openlattice.chronicle.util.SsrfValidator

// Create a safe HTTP client with default config
val client = SafeHttpClientFactory.createClient()

// Create a safe HTTP client with custom allowed hosts
val config = SsrfConfig(
    allowedHosts = setOf("api.example.com", "auth.example.com"),
    allowedProtocols = setOf("https")
)
val customClient = SafeHttpClientFactory.createClient(config)

// Validate a URL before use
SsrfValidator.validateUrl("https://api.example.com/data", config)

// RetrofitFactory automatically includes SSRF protection
val retrofit = RetrofitFactory.newClient(baseUrl, jwtTokenSupplier)
```

#### Verification

```bash
# Test that Auth0 calls work (should succeed)
# The application should successfully authenticate and make API calls to Auth0

# Test private IP blocking
# Attempting to make a request to a private IP should throw SsrfException
# Example: Trying to access http://192.168.1.1 or http://10.0.0.1

# Test localhost blocking
# Attempting to make a request to localhost should throw SsrfException
# Example: Trying to access http://127.0.0.1 or http://localhost

# Test metadata IP blocking
# Attempting to access cloud metadata should throw SsrfException
# Example: Trying to access http://169.254.169.254/latest/meta-data/

# Test protocol blocking
# Attempting to use file:// or other protocols should throw SsrfException
# Example: Trying to access file:///etc/passwd

# Check logs for blocked SSRF attempts
grep "SSRF:" /var/log/chronicle/server.log
```

#### Integration with Existing Code

SSRF protection is automatically applied to:
1. **RetrofitFactory**: All Retrofit clients created via `RetrofitFactory.newClient()` or `RetrofitFactory.okHttpClient()` include SSRF protection
2. **Auth0ApiExtension**: The Auth0 API client automatically validates requests against the SSRF allowlist
3. **Any code using SafeHttpClientFactory**: Direct usage of `SafeHttpClientFactory.createClient()` includes all protections

#### CVEs Mitigated

- CWE-918: Server-Side Request Forgery (SSRF)
- OWASP Top 10 A10:2021 - Server-Side Request Forgery
- AWS IMDS attacks via 169.254.169.254
- GCP/Azure metadata service attacks
- Internal network reconnaissance via SSRF
- Protocol smuggling attacks

### Error Response Sanitization
**What**: Prevents information disclosure through error responses by sanitizing stack traces, internal paths, SQL queries, and class names.
**Why**: Error messages can leak sensitive information that helps attackers understand the internal architecture, identify vulnerabilities, and craft targeted attacks.
**Files**: `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/ErrorSanitizationConfig.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ChronicleServerExceptionHandler.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/ApiError.kt`, `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/SanitizedErrorAttributes.kt`

#### Information Disclosure Risks Mitigated

| Risk | Information Leaked | Protection |
|------|-------------------|------------|
| Stack Traces | Internal code structure, file paths, library versions | Removed in production, error ID returned instead |
| SQL Errors | Database schema, table names, query structure | Always sanitized, generic error returned |
| Class Names | Technology stack, internal architecture | Removed from error messages |
| File Paths | Server directory structure, deployment info | Scrubbed using regex patterns |
| Exception Types | Framework and library information | Generic error types returned |

#### Error Response Categories

| Status Code | Response Type | Details Exposed |
|-------------|--------------|-----------------|
| 400 | Bad Request | Field validation errors (field names and validation messages only) |
| 401 | Unauthorized | Generic "Authentication required" - no specifics |
| 403 | Forbidden | Generic "Access denied" - no specifics |
| 404 | Not Found | Generic "Resource not found" - no specifics |
| 409 | Conflict | Sanitized state error message |
| 500 | Internal Server Error | Generic message with error ID for correlation |

#### Error ID Correlation

Every error generates a unique error ID in the format `ERR-{UUID}`:
- The error ID is returned to the client in the response
- Full error details including stack traces are logged server-side with the error ID
- Support teams can correlate client-reported issues with server logs

Example error response:
```json
{
    "status": 500,
    "error": "Internal Server Error",
    "message": "An unexpected error occurred. Please contact support with error ID: ERR-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "errorId": "ERR-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "timestamp": "2024-01-15T10:30:00Z",
    "path": "/api/v3/study/123"
}
```

#### Sensitive Pattern Scrubbing

The following patterns are automatically scrubbed from error messages:

| Pattern Type | Examples | Replacement |
|--------------|----------|-------------|
| File Paths | `/home/user/app/src/Main.kt`, `C:\Users\...` | `[REDACTED]` |
| SQL Fragments | `SELECT * FROM users WHERE...` | `[REDACTED]` |
| Internal Classes | `com.openlattice.chronicle.services.StudyService` | `[REDACTED]` |
| Connection Strings | `jdbc:postgresql://localhost:5432/...` | `[REDACTED]` |
| Credentials | `password=secret`, `Bearer token...` | `[REDACTED]` |

#### Configuration

Configure error sanitization in `error-sanitization.yaml`:

```yaml
# error-sanitization.yaml
sanitize-errors: true           # Enable message sanitization
include-stack-trace: false      # Exclude stack traces from responses
include-error-id: true          # Include error ID for correlation
log-full-errors: true           # Log full details server-side
max-message-length: 500         # Maximum message length

# Patterns that are ALWAYS sanitized (even if sanitize-errors is false)
always-sanitize-patterns:
  - ".*SQLException.*"
  - ".*JDBIException.*"
  - ".*DataAccessException.*"
```

| Setting | Production | Development | Purpose |
|---------|------------|-------------|---------|
| `sanitize-errors` | `true` | `false` | Sanitize error messages |
| `include-stack-trace` | `false` | `true` | Include stack traces |
| `include-error-id` | `true` | `true` | Include error ID |
| `log-full-errors` | `true` | `true` | Log full details server-side |

#### Verification

```bash
# Test that 500 errors return generic message
curl -X POST http://localhost:8081/api/cause-error
# Expected: Generic message with error ID, no stack trace

# Check server logs for full error details
grep "ERR-" /var/log/chronicle/server.log
# Expected: Full stack trace with error ID

# Test validation errors include field details
curl -X POST http://localhost:8081/api/v3/study \
  -H "Content-Type: application/json" \
  -d '{"title": ""}'
# Expected: 400 with field validation errors

# Test SQL errors are always sanitized
# Trigger a database error and verify no SQL is exposed in response
```

#### Development Mode

For local development, use `error-sanitization-local.yaml`:
- Stack traces are included in responses
- Full error messages are shown
- SQL errors are still sanitized (good practice)

To enable development mode:
```bash
cp chronicle-server/src/main/resources/error-sanitization-local.yaml \
   chronicle-server/src/main/resources/error-sanitization.yaml
```

#### CVEs Mitigated

- CWE-209: Information Exposure Through an Error Message
- CWE-497: Exposure of System Data to an Unauthorized Control Sphere
- CWE-200: Exposure of Sensitive Information to an Unauthorized Actor
- OWASP Top 10 A01:2021 - Broken Access Control (information disclosure)

---

## Attack Surface Summary

### Frontend (React)
| Attack | Mitigation |
|--------|------------|
| XSS | CSP, React escaping |
| CSRF | SameSite cookies, CORS |
| Clickjacking | X-Frame-Options, frame-ancestors |

### Backend (Spring/Kotlin)
| Attack | Mitigation |
|--------|------------|
| SQL Injection | Parameterized queries + SqlIdentifierValidator |
| Deserialization RCE | Jackson default typing disabled |
| Mass Assignment | @Valid + FAIL_ON_UNKNOWN_PROPERTIES |
| Path Traversal | Input validation |
| DoS | Request size limits, timeouts |
| Timing Attack | SecureCompare (constant-time comparison) |
| Open Redirect | RedirectValidator + OpenRedirectFilter |
| Log Injection | LogSanitizer utility |
| XXE | SecureXmlFactory |
| HTTP Parameter Pollution | ParameterPollutionFilter |
| Request Tampering (Mobile) | HMAC-SHA256 signing |
| Replay Attacks (Mobile) | Timestamp + Nonce validation |
| Brute Force / API Abuse | Bucket4j + Hazelcast rate limiting |
| SSRF | SsrfValidator + SafeHttpClientFactory |
| Information Disclosure | Error response sanitization + error ID correlation |

### Database (PostgreSQL)
| Attack | Mitigation |
|--------|------------|
| Unauthorized Access | RLS policies |
| Data Theft | TDE encryption |
| SQL Injection | Prepared statements + identifier validation |

---

## Configuration Values

### Timeouts
| Setting | Value | Rationale |
|---------|-------|-----------|
| Connection idle | 30s | Kill slow loris attacks |
| Thread idle | 60s | Reclaim unused threads |
| Request read | 10s | Don't wait forever for slow clients |

### Size Limits
| Setting | Value | Rationale |
|---------|-------|-----------|
| Request body | 10MB | Prevent memory exhaustion |
| Request headers | 8KB | Prevent header bomb |
| Form keys | 1000 | Prevent form DoS |

### Security Headers
| Header | Value | Rationale |
|--------|-------|-----------|
| Content-Security-Policy | See nginx config | Prevent XSS/injection |
| X-Frame-Options | DENY | Prevent clickjacking |
| X-Content-Type-Options | nosniff | Prevent MIME sniffing |
| Referrer-Policy | strict-origin-when-cross-origin | Limit referrer leakage |

---

## Verification Commands

```bash
# Test all security headers are present
curl -I https://your-domain.com/ 2>/dev/null | grep -E "(Content-Security-Policy|X-Frame-Options|X-Content-Type-Options|Referrer-Policy|Strict-Transport-Security|Cross-Origin|Permissions-Policy)"

# Expected output should include:
# Content-Security-Policy: default-src 'self'; script-src 'self' ...
# X-Frame-Options: DENY
# X-Content-Type-Options: nosniff
# Referrer-Policy: strict-origin-when-cross-origin
# Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
# Cross-Origin-Opener-Policy: same-origin
# Cross-Origin-Resource-Policy: same-origin
# Permissions-Policy: accelerometer=(), camera=(), ...

# Test CSP specifically
curl -I https://your-domain.com/ 2>/dev/null | grep -i "content-security-policy"

# Test request size limit
dd if=/dev/zero bs=1M count=15 | curl -X POST -d @- https://your-domain.com/api/test
# Should return 413

# Test RLS
./docker/test-rls.sh

# Test TDE
./docker/verify-encryption.sh

# Test PostgreSQL SSL/TLS encryption in transit
docker exec chronicle-postgres psql -U chronicle -c "SHOW ssl;"
# Expected: on

# Verify SSL connections
docker exec chronicle-postgres psql -U chronicle -c "
SELECT datname, ssl, version as tls_version, cipher
FROM pg_stat_ssl JOIN pg_stat_activity ON pg_stat_ssl.pid = pg_stat_activity.pid
WHERE datname = 'chronicle';"
# Expected: ssl=t, tls_version=TLSv1.2 or TLSv1.3

# Verify certificate chain
docker exec chronicle-postgres openssl verify \
    -CAfile /var/lib/postgresql/ssl/ca.crt \
    /var/lib/postgresql/ssl/server.crt
# Expected: server.crt: OK

# Check certificate expiration
docker exec chronicle-postgres openssl x509 \
    -in /var/lib/postgresql/ssl/server.crt \
    -noout -dates

# Run OWASP dependency scan on all projects
./gradlew dependencyCheckAll

# Run dependency scan on a specific project
./gradlew :chronicle-server:dependencyCheckAnalyze

# Collect all security reports
./gradlew aggregateSecurityReports

# Run npm audit in chronicle-web
cd chronicle-web && npm run audit:ci

# Generate npm audit JSON report
cd chronicle-web && npm run security
```

### Browser DevTools Verification
1. Open Chrome DevTools (F12) > Network tab
2. Load the page and select the main document request
3. Check Response Headers for all security headers
4. Console tab should show no CSP violations (unless there are issues)
5. To test clickjacking protection: Try embedding the site in an iframe on another domain - it should be blocked
