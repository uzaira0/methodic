---
name: Freshness dashboard
about: Pinned dashboard rolling up the four freshness audit reports
title: "freshness:dashboard — keep pinned"
labels: ["freshness:dashboard"]
assignees: []
---

# Freshness Dashboard

This issue rolls up the four cron-driven freshness audit reports. Each section
links to the source issue maintained by its respective audit workflow. Pin this
issue and check it weekly.

## JVM dependencies
See: most recent issue with label `freshness:jvm`.

Workflow: `.github/workflows/freshness-jvm.yml` (Mondays 08:00 UTC).
Source: `./gradlew dependencyUpdates -Drevision=release`.

## Bun (chronicle-web) dependencies
See: most recent issue in `uzaira0/chronicle-web` with label `freshness:bun`.

Workflow: `chronicle-web/.github/workflows/freshness-bun.yml`.
Source: `bun outdated`.

## Plugin drift across submodules
See: most recent issue with label `freshness:plugin-drift`.

Workflow: `.github/workflows/freshness-plugin-drift.yml`.
Source: `./scripts/plugin-drift-detect.sh` (compares each submodule's
`build.gradle` plugin pins against canonical `settings.gradle.kts`).

## GitHub Actions pin freshness
See: most recent issue with label `freshness:actions`.

Workflow: `.github/workflows/freshness-actions.yml`.
Source: `./scripts/freshness-actions.sh` (resolves each `uses:` pin against
the latest release of that action's repo).
