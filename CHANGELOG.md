# Changelog

## [Unreleased]

## [2026.09.04]

### Added

- Android Internal Testing build 58 (`2026.09.03-internal.open.1`): the open flavor with translation support, built and uploaded from local CI.
- `make changelog RELEASE=<version>` drafts the changelog entry from the commits staged for publish.

### Changed

- Public history is curated: `make publish-stage` lays the filtered private tree over the public tip and `make publish-push` fast-forwards the logical commits built from it, gated by a secrets scan and a commit-message check. Commit messages follow Conventional Commits; `docs/GIT-WORKFLOW.md` describes the model.

### Fixed

- The self-host Grafana viewer helper crashed on Python 3.9 because of a postponed-annotation syntax in a signature.
- The capability-ownership check looked for English UI text that now lives in the translation table.

### Security

- Web dependencies: fast-uri 4.1.4, browserslist 4.28.8, and qs 6.16.0 close the advisories reported by `bun audit`.

## [2026.09.03]

### Added

- Translation support across the web dashboard, Android app, iOS app, and server-sent messages: English base tables with per-language override hooks, `Accept-Language` on every client call, and a dev-only `en-XA` pseudo-locale. Upstream Spanish, German, Swedish, and Hebrew diary wording is preserved verbatim.
- A hardcoded-string gate for every surface (`make i18n-lint`), with a table-driven proof suite and a mutation test (`make i18n-lint-proof`).
- Publishing from the private development repositories to the public mirrors, gated by a secrets scan and a `.publishignore` per repository.
- `CONTRIBUTING.md`, `SECURITY.md`, and `docs/GIT-WORKFLOW.md`.

### Changed

- All continuous integration now runs locally (`lefthook`, `scripts/local-ci.sh`). The GitHub Actions workflows and the checks that inspected them were retired; the Maestro emulator runner scripts moved to `tests/maestro/`.
- Android `SetTextI18n` is now a build error, and debug builds enable pseudolocales.


### Security

- The shared JVM dependency policy now requires RabbitMQ Java client 5.34.0 and verifies the new RabbitMQ/Netty artifacts used by the server and Rhizome builds.

### Fixed

- Public selfhost deployments now admit the Android app's bounded startup synchronization burst while retaining per-client edge and backend rate limits. [#159](https://github.com/uzaira0/methodic/pull/159)
