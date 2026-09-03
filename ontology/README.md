# Chronicle LinkML Ontology

`chronicle.linkml.yaml` is the seed schema for moving Chronicle toward a
single source of truth for shared contracts.

The current codebase still has Kotlin/Swift/TypeScript/Android constants and
configuration classes that predate this schema. The first generator now emits:

- `docs/generated/chronicle-contracts.md`
- `chronicle-web/src/modern/generated/chronicle-contracts.ts`

The security guardrail compares high-risk Kotlin enums against this LinkML file
and fails if generated artifacts are stale, so new values cannot drift silently.

Authoritative migration rule:

- edit LinkML first for cross-platform/domain concepts
- regenerate downstream artifacts with `scripts/generate-chronicle-contracts.py`
- do not hand-edit generated artifacts
- keep deployment-specific secrets and environment values outside LinkML
