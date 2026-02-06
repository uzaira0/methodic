# Mobile API Security - HMAC Request Signing and Replay Prevention

This document describes the HMAC request signing and replay prevention mechanisms implemented for the `/api/mobile/*` endpoints in Chronicle.

## Overview

The mobile API security layer provides two critical protections:

1. **Request Signing (HMAC-SHA256)**: Ensures request integrity - any tampering with the request invalidates the signature
2. **Replay Prevention**: Prevents captured requests from being re-sent via timestamp validation and nonce tracking

## Why This Is Needed

| Threat | Impact | Mitigation |
|--------|--------|------------|
| Request Tampering (MITM) | Attacker can modify request bodies, inject malicious data | HMAC signature verification |
| Replay Attacks | Captured requests can be re-sent to duplicate data or exhaust limits | Timestamp + Nonce validation |
| Data Integrity | Ensure data was not modified in transit | SHA-256 body hash in signature |

## Architecture

```
Mobile App                    Chronicle Server
    |                              |
    | 1. Compute signature         |
    |    (HMAC-SHA256)            |
    |                              |
    | 2. Send request with headers |
    |------------------------------>|
    |  X-Chronicle-Signature       | 3. Validate timestamp
    |  X-Chronicle-Timestamp       |    (reject if >5min old)
    |  X-Chronicle-Nonce           |
    |                              | 4. Check nonce in Hazelcast
    |                              |    (reject if duplicate)
    |                              |
    |                              | 5. Compute expected signature
    |                              |
    |                              | 6. Compare signatures
    |                              |    (constant-time)
    |                              |
    |<-----------------------------|
    | Response or 401 Unauthorized |
```

## Required Headers

All requests to `/api/mobile/*` endpoints must include these headers:

| Header | Description | Example |
|--------|-------------|---------|
| `X-Chronicle-Signature` | Base64-encoded HMAC-SHA256 signature | `a3f2b7c8d9e0f1...` |
| `X-Chronicle-Timestamp` | Unix epoch timestamp (seconds) | `1704067200` |
| `X-Chronicle-Nonce` | UUID to prevent replay attacks | `550e8400-e29b-41d4-a716-446655440000` |

## Signature Computation

### Algorithm

The signature is computed as follows:

1. **Create the signing string**:
   ```
   METHOD|PATH|TIMESTAMP|NONCE|SHA256(BODY)
   ```

2. **Compute HMAC-SHA256** of the signing string using the shared secret

3. **Base64-encode** the result

### Example (Pseudocode)

```kotlin
// 1. Prepare components
val method = "POST"
val path = "/api/mobile/data/upload"
val timestamp = "1704067200"
val nonce = UUID.randomUUID().toString()
val bodyHash = SHA256(requestBody).toHexString()

// 2. Build signing string
val signingString = "$method|$path|$timestamp|$nonce|$bodyHash"

// 3. Compute HMAC
val hmac = HMAC_SHA256(signingString, sharedSecret)

// 4. Base64 encode
val signature = Base64.encode(hmac)

// 5. Set headers
request.setHeader("X-Chronicle-Signature", signature)
request.setHeader("X-Chronicle-Timestamp", timestamp)
request.setHeader("X-Chronicle-Nonce", nonce)
```

### Swift (iOS) Example

```swift
import CommonCrypto
import Foundation

func signRequest(method: String, path: String, body: Data, secret: String) -> (signature: String, timestamp: String, nonce: String) {
    let timestamp = String(Int(Date().timeIntervalSince1970))
    let nonce = UUID().uuidString

    // Compute SHA-256 hash of body
    var bodyHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    body.withUnsafeBytes {
        _ = CC_SHA256($0.baseAddress, CC_LONG(body.count), &bodyHash)
    }
    let bodyHashHex = bodyHash.map { String(format: "%02x", $0) }.joined()

    // Build signing string
    let signingString = "\(method)|\(path)|\(timestamp)|\(nonce)|\(bodyHashHex)"

    // Compute HMAC-SHA256
    let secretData = Data(secret.utf8)
    let signingData = Data(signingString.utf8)
    var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

    signingData.withUnsafeBytes { signingBytes in
        secretData.withUnsafeBytes { secretBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                   secretBytes.baseAddress, secretData.count,
                   signingBytes.baseAddress, signingData.count,
                   &hmac)
        }
    }

    let signature = Data(hmac).base64EncodedString()
    return (signature, timestamp, nonce)
}
```

### Kotlin (Android) Example

```kotlin
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

fun signRequest(
    method: String,
    path: String,
    body: ByteArray,
    secret: String
): Triple<String, String, String> {
    val timestamp = (System.currentTimeMillis() / 1000).toString()
    val nonce = UUID.randomUUID().toString()

    // Compute SHA-256 hash of body
    val digest = MessageDigest.getInstance("SHA-256")
    val bodyHash = digest.digest(body).joinToString("") { "%02x".format(it) }

    // Build signing string
    val signingString = "$method|$path|$timestamp|$nonce|$bodyHash"

    // Compute HMAC-SHA256
    val mac = Mac.getInstance("HmacSHA256")
    val secretKey = SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA256")
    mac.init(secretKey)
    val hmacBytes = mac.doFinal(signingString.toByteArray(Charsets.UTF_8))

    val signature = Base64.getEncoder().encodeToString(hmacBytes)
    return Triple(signature, timestamp, nonce)
}
```

## Validation Rules

### Timestamp Validation

| Rule | Value | Rationale |
|------|-------|-----------|
| Maximum request age | 5 minutes | Limit replay window |
| Clock skew allowance | 30 seconds | Account for device clock drift |
| Future timestamp limit | 30 seconds ahead | Prevent pre-computed attacks |

### Nonce Validation

- Must be a valid UUID format
- Must be unique within the TTL window (10 minutes)
- Nonces are stored in Hazelcast distributed cache
- Duplicate nonces are rejected (replay detection)

### Signature Validation

- Uses constant-time comparison (`MessageDigest.isEqual()`)
- Prevents timing attacks

## Configuration

Configuration is loaded from `mobile-security.yaml`:

```yaml
# Enable/disable signature verification
enabled: true

# Shared secret (minimum 256 bits / 32 bytes recommended)
# IMPORTANT: Use a secure, randomly generated secret in production!
signing-secret: "your-256-bit-secret-key-here-min-32-chars"

# Whether signing is mandatory (false allows gradual rollout)
signing-required: false

# Maximum age of requests in minutes
max-request-age-minutes: 5

# Allowed clock skew in seconds
clock-skew-seconds: 30

# TTL for nonces in cache (should be > max-request-age + clock-skew)
nonce-ttl-minutes: 10
```

## Deployment Strategy

### Phase 1: Monitor Mode (signing-required: false)

1. Deploy server with signature verification enabled
2. Mobile clients begin sending signed requests
3. Unsigned requests are still allowed (for backward compatibility)
4. Server logs warnings for unsigned requests
5. Monitor logs to ensure clients are signing correctly

### Phase 2: Enforcement Mode (signing-required: true)

1. Verify all active mobile app versions are signing requests
2. Set `signing-required: true` in configuration
3. All unsigned requests will receive 401 Unauthorized
4. Monitor for any issues with older clients

## Error Responses

| HTTP Status | Error | Cause |
|-------------|-------|-------|
| 400 Bad Request | Invalid timestamp format | Timestamp is not a valid Unix epoch |
| 400 Bad Request | Invalid nonce format | Nonce is not a valid UUID |
| 401 Unauthorized | Missing required signature headers | One or more headers missing (when enforced) |
| 401 Unauthorized | Request timestamp has expired | Request is too old (>5 minutes) |
| 401 Unauthorized | Request timestamp is in the future | Clock skew exceeds tolerance |
| 401 Unauthorized | Request replay detected | Nonce has been used before |
| 401 Unauthorized | Invalid request signature | Signature does not match |

## Security Considerations

### Secret Management

1. **Never hardcode** the signing secret in mobile apps
2. Use secure storage:
   - iOS: Keychain
   - Android: EncryptedSharedPreferences or Android Keystore
3. Consider using a key derivation scheme where each device has a unique secret
4. Plan for secret rotation

### Secret Rotation

When rotating secrets:

1. Support multiple active secrets during transition
2. Include secret version/ID in signature headers
3. Gradually migrate devices to new secret
4. Revoke old secret after migration complete

### Logging

The filter logs security events:

- `WARN`: Missing signature headers (in monitor mode)
- `WARN`: Invalid timestamp format
- `WARN`: Timestamp validation failures
- `WARN`: Invalid nonce format
- `WARN`: Replay attack detected (duplicate nonce)
- `WARN`: Invalid signature
- `DEBUG`: Successful signature verification

## Testing

### Test Valid Signature

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

### Test Replay Detection

```bash
# Re-send the same request with same nonce
# Should return 401 with "Request replay detected"
curl -X POST http://localhost:8081/api/mobile/test \
  -H "Content-Type: application/json" \
  -H "X-Chronicle-Signature: $SIGNATURE" \
  -H "X-Chronicle-Timestamp: $TIMESTAMP" \
  -H "X-Chronicle-Nonce: $NONCE" \
  -d "$BODY"
```

### Test Expired Timestamp

```bash
# Use timestamp from 10 minutes ago
OLD_TIMESTAMP=$(($(date +%s) - 600))
# ... (compute signature with old timestamp)
# Should return 401 with "Request timestamp has expired"
```

## Files

| File | Description |
|------|-------------|
| `MobileApiSignatureFilter.kt` | Main filter implementing HMAC validation |
| `CachedBodyHttpServletRequest.kt` | Request wrapper for body caching |
| `MobileApiSecurityConfig.kt` | Spring configuration and bean registration |
| `mobile-security.yaml` | Configuration file |

## Related Documentation

- [SECURITY-HARDENING.md](./SECURITY-HARDENING.md) - Overall security hardening documentation
- [HIPAA Compliance Audit Trail](../chronicle-server/docs/AUDIT.md) - Audit logging for PHI access
