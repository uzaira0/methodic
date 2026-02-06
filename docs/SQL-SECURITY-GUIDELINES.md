# SQL Security Guidelines

This document provides security guidelines for writing safe SQL queries in the Chronicle codebase to prevent SQL injection vulnerabilities.

## Quick Reference

| Scenario | Safe Approach | Forbidden Pattern |
|----------|---------------|-------------------|
| User input in WHERE clause | `WHERE id = ?` + `setObject(1, userId)` | `WHERE id = '$userId'` |
| Dynamic values | Parameterized query | String interpolation |
| Dynamic table names | `SqlIdentifierValidator.validateTableName()` | Direct string interpolation |
| Temp table names | `SqlIdentifierValidator.validateTempTableName()` | Unvalidated random strings |
| Numeric values | Type-safe binding | String interpolation |

---

## SQL Injection Overview

SQL injection occurs when untrusted data is concatenated or interpolated into SQL queries, allowing attackers to execute arbitrary SQL commands.

### Attack Example

```kotlin
// VULNERABLE - attacker can inject SQL
val userId = "'; DROP TABLE users; --"
handle.createQuery("SELECT * FROM users WHERE id = '$userId'").mapTo<User>()
// Resulting SQL: SELECT * FROM users WHERE id = ''; DROP TABLE users; --'
```

### Safe Example

```kotlin
// SAFE - parameterized query
handle.createQuery("SELECT * FROM users WHERE id = :userId")
    .bind("userId", userId)
    .mapTo<User>()
```

---

## Rule 1: Always Use Parameterized Queries

For all dynamic values in SQL queries, use parameter placeholders.

### JDBI Named Parameters (Preferred)

```kotlin
// SAFE: Named parameters with JDBI
connection.prepareStatement("""
    SELECT * FROM participants
    WHERE study_id = :studyId AND status = :status
""").use { ps ->
    ps.bind("studyId", studyId)
    ps.bind("status", status)
    ps.executeQuery()
}
```

### JDBC Positional Parameters

```kotlin
// SAFE: Positional parameters with JDBC
connection.prepareStatement("""
    SELECT * FROM participants
    WHERE study_id = ? AND status = ?
""").use { ps ->
    ps.setObject(1, studyId)
    ps.setString(2, status)
    ps.executeQuery()
}
```

### Forbidden Patterns

```kotlin
// FORBIDDEN: String interpolation
handle.createQuery("SELECT * FROM users WHERE id = '$userId'")

// FORBIDDEN: String concatenation
handle.createQuery("SELECT * FROM users WHERE id = '" + userId + "'")

// FORBIDDEN: Template strings
handle.createQuery("SELECT * FROM users WHERE id = '${userId}'")
```

---

## Rule 2: Validate Dynamic Identifiers

Table names, column names, and other SQL identifiers cannot be parameterized. When they must be dynamic, use `SqlIdentifierValidator`.

### Validating Table Names

```kotlin
import com.openlattice.chronicle.util.SqlIdentifierValidator

// SAFE: Validated against allowlist
val tableName = SqlIdentifierValidator.validateTableName(userProvidedTable)
stmt.execute("SELECT * FROM $tableName")
```

### Validating Temporary Table Names

```kotlin
// SAFE: Validated temp table name
val tempTableName = "duplicate_events_${RandomStringUtils.randomAlphanumeric(10)}"
val validatedName = SqlIdentifierValidator.validateTempTableName(tempTableName)
stmt.execute("CREATE TEMPORARY TABLE $validatedName ...")
```

### Validating Import Table Names

```kotlin
// SAFE: For tables from configuration (e.g., ImportStudiesConfiguration)
val tableName = SqlIdentifierValidator.validateImportTableName(config.systemAppsTable)
stmt.execute("INSERT INTO target SELECT * FROM $tableName")
```

---

## Rule 3: Use Type-Safe Value Binding

Always use the appropriate `setXxx` method for the data type.

```kotlin
// SAFE: Type-safe binding
ps.setObject(1, uuid)           // UUID
ps.setString(2, text)           // String
ps.setInt(3, count)             // Integer
ps.setTimestamp(4, timestamp)   // Timestamp
ps.setBoolean(5, active)        // Boolean
ps.setArray(6, array)           // Array

// For arrays, use PostgresArrays helper
ps.setArray(1, PostgresArrays.createTextArray(connection, listOfStrings))
ps.setArray(2, PostgresArrays.createUuidArray(connection, listOfUuids))
```

---

## Rule 4: Validate Numeric Configuration Values

Even numeric values should be validated when they come from configuration.

```kotlin
// SAFE: Validated timeout
val timeout = SqlIdentifierValidator.validateTimeout(configuredTimeout)
stmt.execute("SET statement_timeout = '${timeout}ms'")
```

---

## Chronicle-Specific Patterns

### Using PostgresTableDefinition Names

Table names from `PostgresTableDefinition` are safe because they're defined in code:

```kotlin
// SAFE: Using table definition name (compile-time constant)
stmt.execute("INSERT INTO ${ChroniclePostgresTables.PARTICIPANTS.name} ...")
```

### RedshiftDataTables Helper Methods

The `RedshiftDataTables` helper methods generate SQL with validated temp table names:

```kotlin
// SAFE: Using helper methods (must validate tempTableName first)
val tempTableName = SqlIdentifierValidator.validateTempTableName(
    "duplicate_events_${RandomStringUtils.randomAlphanumeric(10)}"
)
stmt.execute(RedshiftDataTables.createTempTableOfDuplicates(tempTableName))
stmt.execute(RedshiftDataTables.getDeleteUsageEventsFromTempTable(tempTableName))
```

### BasePostgresIterable with PreparedStatementHolderSupplier

```kotlin
// SAFE: Parameterized iterable
BasePostgresIterable(
    PreparedStatementHolderSupplier(
        hds,
        "SELECT * FROM participants WHERE study_id = ?"
    ) { ps -> ps.setObject(1, studyId) }
) { rs -> ResultSetAdapters.participant(rs) }
```

---

## Known Safe Patterns

These patterns are safe and should not trigger security warnings:

1. **PostgresTableDefinition.name** - Compile-time constants from enum/object definitions
2. **PostgresColumnDefinition.name** - Compile-time constants from column definitions
3. **Validated temp tables** - Generated names validated through `SqlIdentifierValidator`
4. **Validated import tables** - External table names validated through `SqlIdentifierValidator`

---

## Known Vulnerable Patterns (Audit Findings)

The following patterns were identified during the security audit and require attention:

### 1. Temp Table Name Interpolation

**Location**: `AppDataUploadService.kt`, `MoveToEventStorageTask.kt`, `MoveToIosEventStorageTask.kt`

```kotlin
// BEFORE (vulnerable to injection if randomAlphanumeric is compromised)
val tempTableName = "duplicate_events_${RandomStringUtils.randomAlphanumeric(10)}"
stmt.execute("DROP TABLE $tempTableName")
```

**Fix**: Validate temp table names before use

```kotlin
// AFTER (validated)
val tempTableName = SqlIdentifierValidator.validateTempTableName(
    "duplicate_events_${RandomStringUtils.randomAlphanumeric(10)}"
)
stmt.execute("DROP TABLE $tempTableName")
```

### 2. Import Table Names from Configuration

**Location**: `ImportController.kt`

```kotlin
// BEFORE (relies only on Bean Validation regex)
statement.execute("INSERT INTO ${ChroniclePostgresTables.SYSTEM_APPS.name} SELECT * FROM ${config.systemAppsTable}")
```

**Fix**: Add programmatic validation as defense-in-depth

```kotlin
// AFTER (defense-in-depth validation)
val sourceTable = SqlIdentifierValidator.validateImportTableName(config.systemAppsTable)
statement.execute("INSERT INTO ${ChroniclePostgresTables.SYSTEM_APPS.name} SELECT * FROM $sourceTable")
```

### 3. Statement Timeout Interpolation

**Location**: `BasePostgresIterable.kt`

```kotlin
// BEFORE (assumes statementTimeoutMillis is always safe)
statement.execute("SET statement_timeout = '${statementTimeoutMillis}ms';")
```

**Fix**: Validate timeout values

```kotlin
// AFTER (validated)
val validatedTimeout = SqlIdentifierValidator.validateTimeout(statementTimeoutMillis)
statement.execute("SET statement_timeout = '${validatedTimeout}ms';")
```

---

## Running the SQL Injection Audit

Run the audit script to scan for potential vulnerabilities:

```bash
# Basic audit
./scripts/audit-sql-injection.sh

# Verbose mode (shows all matches with context)
./scripts/audit-sql-injection.sh --verbose

# Show help
./scripts/audit-sql-injection.sh --help
```

---

## Code Review Checklist

When reviewing SQL-related code changes:

- [ ] No string interpolation (`$variable` or `${expression}`) with user input in SQL
- [ ] No string concatenation (`+`) with user input in SQL
- [ ] All dynamic values use parameterized queries
- [ ] Dynamic table/column names validated through `SqlIdentifierValidator`
- [ ] Temp table names use allowed prefixes and are validated
- [ ] Import table names from configuration are validated
- [ ] Numeric configuration values are validated before interpolation
- [ ] PreparedStatement parameters use type-safe `setXxx` methods

---

## Additional Resources

- [OWASP SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
- [PostgreSQL Prepared Statements](https://www.postgresql.org/docs/current/sql-prepare.html)
- [JDBI Documentation](https://jdbi.org/)
- Chronicle Security Hardening: [SECURITY-HARDENING.md](./SECURITY-HARDENING.md)
