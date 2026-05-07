# Production Readiness Handoff — 10 Critical Fixes

**Date:** 2026-05-06
**Status:** All 10 issues analyzed and architecturally designed. Implementation not yet started.
**Branch:** `develop` (all repos)

---

## Issue Summary

| # | Severity | File(s) | Status |
|---|----------|---------|--------|
| 1 | CRITICAL | RLSContextFilter, RLSContextManager, StorageResolver | Designed, not implemented |
| 2 | CRITICAL | `.github/workflows/docker-build-deploy.yml` | Not implemented |
| 3 | CRITICAL | `rhizome/.../S3ListingIterator.kt` | Not implemented |
| 4 | CRITICAL | `chronicle-server/.../AwsBlobDataService.kt` | Not implemented |
| 5 | HIGH | `chronicle-web/.../participant-dashboard-page.tsx` | Not implemented |
| 6 | HIGH | `chronicle-server/.../SqlIdentifierValidator.kt` | Not implemented |
| 7 | MEDIUM | `rhizome-client/.../AmazonLaunchConfiguration.java` | Not implemented |
| 8 | MEDIUM | `chronicle-server/.../VaultConfiguration.kt` | Not implemented |
| 9 | MEDIUM | `chronicle-server/.../AwsBlobDataService.kt` | Not implemented |
| 10 | LOW | `chronicle-web/.../study-operations-api.ts` | Not implemented |

---

## Issue 1 — RLS Context Bypass (CRITICAL)

**Bug:** `RLSContextFilter` borrows a connection from the pool, sets RLS session variables (`app.current_user_id`, `app.authorized_studies`, `app.is_admin`) via `set_config(_, _, true)` (transaction-local), then immediately returns that connection to the pool. When `filterChain.doFilter()` runs, downstream controllers get *different* pooled connections that have NO RLS context. The `true` parameter makes the config transaction-local, which evaporates after the implicit autocommit transaction.

**Root cause:** RLS vars are set on Connection A, but controllers use Connection B/C/D from the pool.

**Fix design (fully worked out):**

### New file: `chronicle-server/.../storage/rls/RLSContext.kt`

ThreadLocal holder for per-request auth data:

```kotlin
data class RLSContextData(
    val principalId: String,
    val authorizedStudies: String,  // comma-separated UUIDs
    val isAdmin: Boolean
)

object RLSContext {
    private val holder = ThreadLocal<RLSContextData?>()
    fun set(data: RLSContextData) = holder.set(data)
    fun get(): RLSContextData? = holder.get()
    fun clear() = holder.remove()
}
```

### New file: `chronicle-server/.../storage/rls/RLSDataSourceWrapper.kt`

Wraps a `javax.sql.DataSource`. On every `getConnection()`:
- Reads `RLSContext.get()` from ThreadLocal
- If non-null: executes `SET SESSION` / `set_config(_, _, false)` (session-local, persists for connection lifetime)
- Returns a wrapped `Connection` that clears RLS vars on `close()` (before returning to pool)
- If ThreadLocal is empty (background jobs): skips context setting → RLS default-deny applies

```kotlin
class RLSDataSourceWrapper(
    private val delegate: DataSource,
    private val hikariDataSource: HikariDataSource  // for eviction on clear failure
) : DataSource by delegate {
    override fun getConnection(): Connection {
        val conn = delegate.connection
        val ctx = RLSContext.get()
        if (ctx != null) {
            setRLSVars(conn, ctx)
        }
        return RLSConnectionWrapper(conn, hikariDataSource)
    }
}

class RLSConnectionWrapper(
    private val delegate: Connection,
    private val hikariDataSource: HikariDataSource
) : Connection by delegate {
    override fun close() {
        try { clearRLSVars(delegate) } catch (e: Exception) {
            hikariDataSource.evictConnection(delegate)
        }
        delegate.close()
    }
}
```

### Modify: `RLSContextManager.kt`

- Change `set_config(_, _, true)` → `set_config(_, _, false)` — session-local, not transaction-local
- Same for `CLEAR_RLS_CONTEXT_SQL`
- Add method `resolveCurrentUserContextData(): RLSContextData` that resolves auth data (principal, authorized studies, isAdmin) without touching a connection

### Modify: `RLSContextFilter.kt`

- Remove connection borrowing entirely
- Instead: resolve auth data via `rlsContextManager.resolveCurrentUserContextData()`, store in `RLSContext.set(data)`
- Clear in `finally` block after `filterChain.doFilter()`

### Modify: `StorageResolver.kt`

- `getPlatformStorage()` and `getPlatformReadStorage()` return `javax.sql.DataSource` (not `HikariDataSource`)
- Wrap the underlying `HikariDataSource` with `RLSDataSourceWrapper`
- Event storage methods (`resolve`, `getEventStorageWithFlavor`, `getDefaultEventStorage`) keep returning `HikariDataSource` — Redshift doesn't use PG RLS

### Test impact:

4 test files mock `HikariDataSource` directly and will need updating:
- `ApiKeyServiceTest.kt`
- `DashboardServiceTest.kt`
- `EnrollmentServiceTest.kt`
- `ExportServiceTest.kt`

---

## Issue 2 — docker-build-deploy.yml: No Approval Gate (CRITICAL)

**File:** `/home/opt/chronicle/.github/workflows/docker-build-deploy.yml`

**Bug:** Pushes to `main` or `develop` trigger a production deployment with no manual approval. This bypasses the `cd.yml` workflow's approval gate.

**Fix:**
```yaml
concurrency:
  group: deploy-production
  cancel-in-progress: false

jobs:
  deploy:
    environment: production   # <-- requires manual approval in GitHub environment settings
    runs-on: self-hosted
```

Also restrict the trigger to `main` only (not `develop`).

---

## Issue 3 — S3ListingIterator Pagination Bug (CRITICAL)

**File:** `rhizome/src/main/kotlin/com/geekbeast/rhizome/aws/S3ListingIterator.kt:35`

**Bug:** `if (index == result.commonPrefixes().size)` hardcodes `commonPrefixes()` but `S3ObjectIterator` overrides `getBufferLength()` to use `contents().size`. When iterating objects (not prefixes), `commonPrefixes().size` is always 0, causing a re-fetch on every single `next()` call.

**Fix:** Line 35: `result.commonPrefixes().size` → `getBufferLength()`

---

## Issue 4 — S3Client/S3Presigner Resource Leak (CRITICAL)

**File:** `chronicle-server/.../storage/aws/AwsBlobDataService.kt:40-41`

**Bug:** `s3` and `presigner` are created in the constructor but never closed. Both hold HTTP connection pools and background threads.

**Fix:** Implement `AutoCloseable` and add `@PreDestroy`:
```kotlin
@Service
class AwsBlobDataService(...) : ByteBlobDataManager, AutoCloseable {
    @PreDestroy
    override fun close() {
        s3.close()
        presigner.close()
    }
}
```

---

## Issue 5 — Participant Dashboard Missing CSRF (HIGH)

**File:** `chronicle-web/src/modern/routes/participant-dashboard-page.tsx:63`

**Bug:** `fetch(url, { credentials: 'include' })` sends the auth cookie but no `X-CSRF-Token` header. The backend's CSRF check will reject this.

**Fix:** Export `getCsrfToken()` and `fetchWithCsrf()` from `study-operations-api.ts` (currently module-private at lines 227-237), then use `fetchWithCsrf` in `participant-dashboard-page.tsx`.

---

## Issue 6 — SQL Identifier Validator Allows Dots (HIGH)

**File:** `chronicle-server/.../util/SqlIdentifierValidator.kt:255`

**Bug:** `^[a-zA-Z0-9_.-]+$` allows dots, enabling `information_schema.columns` as a valid table name. Used in `ImportController.kt:416` where `sourceTable` is interpolated into raw SQL at line 419.

**Fix:** Tighten regex to `^[a-zA-Z_][a-zA-Z0-9_]*$` — no dots, no hyphens, must start with letter or underscore.

---

## Issue 7 — Wrong @JsonProperty on AmazonLaunchConfiguration (MEDIUM)

**File:** `rhizome-client/.../AmazonLaunchConfiguration.java:33`

**Bug:** `@JsonProperty(AwsLaunchConfiguration.BUCKET_FIELD)` on `getRegion()` method. Should be `REGION_FIELD`.

**Fix:** Change `BUCKET_FIELD` → `REGION_FIELD`.

---

## Issue 8 — Vault Defaults to HTTP (MEDIUM)

**File:** `chronicle-server/.../configuration/VaultConfiguration.kt:11`

**Bug:** Default address is `http://vault:8200` — plaintext HTTP for a secrets manager.

**Fix:** Change to `https://vault:8200`.

---

## Issue 9 — AwsBlobDataService Wrong Catch Type (MEDIUM)

**File:** `chronicle-server/.../storage/aws/AwsBlobDataService.kt:157`

**Bug:** `catch (e: S3Exception)` in `getPresignedUrl()`. Presigning is a local operation (no S3 call) — it throws `SdkClientException`, not `S3Exception`. The wrong catch type means presigning errors propagate as unhandled.

**Fix:** Change `S3Exception` → `SdkException` (parent of both `SdkClientException` and `S3Exception`).

---

## Issue 10 — Frontend `any` Casts (LOW)

**File:** `chronicle-web/src/modern/state/study-operations-api.ts`

**Bug:** 5 uses of `any` type weaken type safety:
- Line 36: `settings?: Record<string, any>` → `Record<string, unknown>`
- Lines 105-106: `afterValue?: any; beforeValue?: any` → `unknown`
- Line 126: `metadata?: Record<string, any>` → `Record<string, unknown>`
- Lines 217-218: `.filter((p: any) => ...)` and `.map((p: any) => ...)` → `Record<string, unknown>`

---

## Bonus: LocalBlobDataService Resource Leak

**File:** `chronicle-server/.../storage/local/LocalBlobDataService.kt:66-74`

**Bug:** `insertEntity()` doesn't use `use {}` blocks for connection and preparedStatement. If `setBytes()` or `execute()` throws, both leak.

**Fix:** Wrap in `connection.use { preparedStatement.use { ... } }`.

---

## Submodule Unpushed Commits

All submodules have unpushed commits on `develop`:

| Submodule | Commits ahead | Summary |
|-----------|--------------|---------|
| chronicle-api | 2 | Joda-Time removal, Java 21 source compat |
| chronicle-server | 3 | AWS SDK v1→v2, Joda removal, Java 21 + JMH + property tests |
| chronicle-web | 2 | SHA-pin actions + biome rules, zod-schemas + parity + Pa11y + OIDC |
| rhizome | 4 | AWS SDK v1→v2, Joda removal, dead dep removal, Java 21 |
| rhizome-client | 3 | AWS SDK v1→v2, Joda removal, Java 21 |
| chronicle (Android) | 0 | Clean |

Root repo has 3 unpushed commits: Trivy removal, action hardening, Joda/AWS refactor.
