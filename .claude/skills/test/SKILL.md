---
name: test
description: "Run Chronicle backend tests. Optional arg: test class or method name filter"
disable-model-invocation: true
---

# Run Chronicle Backend Tests

Requires PostgreSQL on localhost:5434 (db: chronicle, user: oltest/test).

## If argument provided (e.g., `/test StudyTests` or `/test StudyTests.createStudy`):

Run the specific test:
```bash
cd /opt/chronicle && ./gradlew :chronicle-server:test --tests "com.openlattice.chronicle.**.*{arg}*"
```

If the arg contains a dot (e.g., `StudyTests.createStudy`), split into class and method:
```bash
cd /opt/chronicle && ./gradlew :chronicle-server:test --tests "com.openlattice.chronicle.**.*{class}*.{method}"
```

## If no argument:

1. Fast compile check first:
   ```bash
   cd /opt/chronicle && ./gradlew :chronicle-server:compileTestKotlin
   ```

2. If compile succeeds, run all tests:
   ```bash
   cd /opt/chronicle && ./gradlew :chronicle-server:test
   ```

## After tests complete:

Show a summary of passed/failed/skipped from the Gradle output. If any tests failed, show the failure details.
