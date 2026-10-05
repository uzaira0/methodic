# Security policy

Chronicle handles research participant data.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on the affected repository
(**Security → Report a vulnerability**). It reaches the maintainers without creating a
public issue. Include the component, steps to reproduce, and the impact. For a source
checkout, include the commit from `git rev-parse --short HEAD`. For a self-host release
bundle, include `release_version`, `source_revision`, and `public_revision` when present in
the bundle-root `release-manifest.json`; the archive may not contain Git metadata.

Do not open a public issue or pull request for a security problem, and do not test against
deployments you do not operate.

## What to expect

- Acknowledgement of the report, and a first assessment of severity.
- A fix on the default branch, with credit in the changelog unless you prefer to stay anonymous.
- Coordinated disclosure: we ask that you hold details until the fix has shipped.

## Supported versions

Only the tip of each repository's default branch receives security fixes in the source
repositories. For self-host release bundles, see the release guidance in
[`selfhost/README.md`](selfhost/README.md). This reporting clarification does not expand
the release support window: support commitments for shipped releases remain owned by
maintainers, and any change to them requires maintainer approval.
