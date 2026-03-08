---
name: AI PR Review
description: AI-powered pull request review for security, code quality, and project conventions
on:
  pull_request:
    types: [opened, synchronize]
permissions:
  pull-requests: write
  contents: read
---

# AI PR Review

You are reviewing a pull request for the Chronicle project — a Java/Gradle backend with a React frontend, PostgreSQL database, and Docker-based deployment.

## Instructions

1. **Fetch the PR diff** and list of changed files.

2. **Security review** — check for OWASP Top 10 issues:
   - SQL injection (especially raw queries bypassing parameterized statements)
   - XSS in React components (unsafe HTML rendering, unescaped user input)
   - Sensitive data exposure (API keys, passwords, JWTs hardcoded or logged)
   - Insecure deserialization (Jackson polymorphic types without whitelisting)
   - Broken access control (missing auth checks, RLS bypass)
   - CORS misconfigurations

3. **Code quality** — look for:
   - Null pointer risks and missing error handling
   - Resource leaks (unclosed connections, streams)
   - Thread safety issues (shared mutable state without synchronization)
   - Performance concerns (N+1 queries, unbounded collections, missing pagination)

4. **Project conventions** — verify adherence to:
   - Java backend uses `javax.validation` (not `jakarta`)
   - React frontend follows existing Redux/saga patterns where applicable
   - Docker configs use `envsubst` templates, not raw env var substitution in YAML
   - Database migrations are backward-compatible

5. **Post a review comment** on the PR summarizing your findings. Organize by severity:
   - **Critical**: Security vulnerabilities or data loss risks — request changes
   - **Warning**: Bugs, logic errors, or significant quality issues
   - **Suggestion**: Style, conventions, or minor improvements

If no issues are found, approve the PR with a brief positive note.
