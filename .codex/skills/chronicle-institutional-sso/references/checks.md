# SSO Audit Checks

Run `scripts/run-sso-drift-audit.sh` before and after auth-migration work.

## Reported categories

- `server_auth0_wiring`
- `server_auth0_defaults`
- `web_bootstrap_paths`
- `web_legacy_user_storage`

## Strict mode

`--strict` fails when Auth0-specific redirect or SSRF defaults reappear in runtime/config docs. This is intended to catch regressions after the explicit-allowlist cleanup.

## Expected current state

- `server_auth0_wiring` still has hits; removal is not complete yet.
- `web_bootstrap_paths` still has hits; `/chronicle/config.json` is still a temporary testing bridge.
- `web_legacy_user_storage` should be shrinking over time; new writes should prefer the neutral storage key.
- `server_auth0_defaults` should stay empty in the main runtime/config surfaces.
