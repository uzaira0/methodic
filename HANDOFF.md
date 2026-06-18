# Production Readiness Handoff — 10 Critical Fixes

**Date:** 2026-05-06 (original analysis) · **Updated:** 2026-06-18 (verified against current code + remediated)
**Status:** All 10 issues now resolved or out-of-scope. CRITICAL #1 was fixed by the HIPAA-2028 RLS work (verified beyond the original design); cloud issues #3/#4/#7/#9 confirmed removed; #10 + bonus already done; #2/#5/#6/#8 fixed 2026-06-18. Per-issue status below.
**Branch:** `develop` (all repos)

---

## Issue Summary

| # | Severity | File(s) | Status |
|---|----------|---------|--------|
| 1 | CRITICAL | RLSContextFilter, RLSRequestContext, StorageResolver | ✅ FIXED — RLSRequestContext + RLSAwareHikariDataSource (session-local `set_config`) + per-request `SET ROLE chronicle_app` so RLS engages despite a superuser pool; V28 control-plane policy split. Verified 2026-06-18. |
| 2 | CRITICAL | `.github/workflows/docker-build-deploy.yml` | ✅ FIXED 2026-06-18 — trigger gated to `main`, `deploy-production` concurrency, `production` environment approval gate. |
| 3 | CRITICAL | Removed legacy cloud object listing path | ✅ Removed (verified 2026-06-18 — no AWS/S3 remnants in built tree). |
| 4 | CRITICAL | Removed legacy cloud blob service path | ✅ Removed (verified) — blob persistence via `LocalBlobDataService`. |
| 5 | HIGH | `chronicle-web/.../participant-dashboard-page.tsx` | ✅ FIXED 2026-06-18 — `fetchWithCsrf` exported + used; TUD-ids GET now carries `X-CSRF-Token`. |
| 6 | HIGH | `chronicle-server/.../SqlIdentifierValidator.kt` | ✅ FIXED 2026-06-18 — segmented validation rejects system catalogs (`pg_*`/`information_schema`) + injection while keeping `schema.table`. |
| 7 | MEDIUM | Removed legacy cloud launch configuration | ✅ Removed (verified). |
| 8 | MEDIUM | `chronicle-server/.../VaultConfiguration.kt` | ✅ FIXED 2026-06-18 — default address `https://localhost:8200`. |
| 9 | MEDIUM | Removed legacy cloud presign path | ✅ Removed (verified) — local presigned-URL path only. |
| 10 | LOW | `chronicle-web/.../study-operations-api.ts` | ✅ FIXED — no `any` casts remain (verified 2026-06-18). |

> **Note (2026-06-18):** The per-issue design sections below are the *original* analysis. The summary table above reflects verified current status. Issue 6's fix intentionally diverges from the original "forbid dots" design — import sources are legitimately schema-qualified (`src.system_apps`), so dots are preserved while system catalogs and injection are blocked. Issue 2's `production` environment only *enforces* approval once protection rules are configured in the repo's GitHub environment settings.

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
- Event storage methods (`resolve`, `getEventStorageWithFlavor`, `getDefaultEventStorage`) keep returning `HikariDataSource` because they target the local Postgres event store separately from the RLS-wrapped platform storage path.

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

## Issue 3 — Legacy Cloud Object Listing Pagination Bug (CRITICAL)

**Status:** Removed from the local BCM deployment path.

**Resolution:** Chronicle local hosting uses local Postgres and local backup replication only. The legacy cloud object listing implementation was removed rather than repaired.

---

## Issue 4 — Legacy Cloud Blob Client Resource Leak (CRITICAL)

**Status:** Removed from the local BCM deployment path.

**Resolution:** The external object-store blob service was removed. Chronicle now routes blob persistence through the local blob data path for this deployment.

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

## Issue 7 — Legacy Cloud Launch Configuration Mapping (MEDIUM)

**Status:** Removed from the local BCM deployment path.

**Resolution:** The unused cloud launch configuration model was deleted rather than repaired.

---

## Issue 8 — Vault Defaults to HTTP (MEDIUM)

**File:** `chronicle-server/.../configuration/VaultConfiguration.kt:11`

**Bug:** Default address is `http://vault:8200` — plaintext HTTP for a secrets manager.

**Fix:** Change to `https://vault:8200`.

---

## Issue 9 — Legacy Cloud Presign Error Handling (MEDIUM)

**Status:** Removed from the local BCM deployment path.

**Resolution:** External object-store presign support is out of scope for local hosting and was removed.

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

## Submodule Push Status (updated 2026-06-18)

| Submodule | Status |
|-----------|--------|
| chronicle-server | ✅ `develop` pushed (0/0 with origin). |
| chronicle-api | ✅ `develop` pushed (0/0). |
| chronicle-models | ✅ `main` pushed (0/0). |
| chronicle-web | ✅ `develop` pushed (0/0). |
| chronicle (Android) | ✅ `develop` pushed (0/0). |
| rhizome | ⚠️ Pinned by root at the AWS-removal commit `6ea3fb66`, which lives on `origin/refactor/data-collection-modularization` — **not merged into `develop`** (whose tip still contains the AWS code). Fresh clone resolves fine; re-bumping from `develop` would regress the cloud removal. |
| rhizome-client | ⚠️ Same as rhizome — pinned at `e168eed` on the refactor branch, not merged to `develop`. |

Root `develop` is in sync with origin.
