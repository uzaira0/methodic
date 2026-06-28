# Mac Studio Dev Workflow

How to develop the **webapp** and **mobile apps** on a Mac Studio that is completely
separate from the production box, while still shipping **backend** changes to the live
backend running on the prod host (10.23.4.137).

**Model:**
- The Mac never touches the prod box directly and never builds the backend.
- The **frontend is not deployed** right now — you run it locally against the live API.
- **Backend** code reaches the box through one branch: `prod-backend`. A poller on the
  box builds + deploys it. You confirm the result from GitHub.

---

## 0. Prereqs on the Mac (one-time)

- `git` and `gh` (GitHub CLI) authenticated to the `uzaira0` account (`gh auth status`).
- `bun` — webapp.
- JDK 21 (`JAVA_HOME` → a JDK 21) — Android app + any backend builds you run locally.
- Xcode — iOS app.
- Android SDK + `adb` — Android app on-device testing.

---

## 1. Clone the monorepo

```bash
git clone --recurse-submodules https://github.com/uzaira0/methodic.git
cd methodic
# if you forgot --recurse-submodules:
git submodule update --init --recursive
```

The submodules integrate on `develop` (except `chronicle-models` on `main`).
`chronicle-server`, `chronicle-api`, and `chronicle-web` `develop` branches are
protected → land changes via PR + rebase-merge, then bump the root pointer.

---

## 2. Webapp (runs locally, NOT deployed)

```bash
cd chronicle-web
bun install --frozen-lockfile

# Run the local dev server pointed at the LIVE backend.
# NOTE: the backend URL is taken from the env var `n` (see scripts/dev-local.ts).
n=https://chronicle-screentime-app.research.bcm.edu bun run dev:local
```

- `dev:local` binds localhost-only (vs `bun run dev`, which binds 0.0.0.0).
- After changing the API contract (`chronicle-api/chronicle.yaml`), regenerate types:
  `bun run generate:api-types`.
- Before pushing: `bun run check` (typecheck + biome + ast-grep + e2e-dsl).

See also `docs/HANDOFF-frontend-local-dev-2026-06-05.md`.

---

## 3. Mobile

- **iOS** (`chronicle-ios`): already targets prod over TLS and HMAC-signs requests.
  Build/enroll on a connected device with automatic signing
  (`xcodebuild -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic
  DEVELOPMENT_TEAM=<team> PROVISIONING_PROFILE_SPECIFIER=`); the real signing secret
  lives in the gitignored `chronicle/Config/Chronicle.local.xcconfig` (regenerate with
  `scripts/generate-ios-config.sh`).
- **Android** (`chronicle/`): build with JDK 21. See `docs/ANDROID-FEATURE-DELTA.md`
  and `docs/HANDOFF-remote-tablet-testing-2026-06-06.md`.

Both already build against the prod backend — no extra wiring.

---

## 4. Ship a backend change to the prod box

This is the **only** action that updates the backend on the box.

1. Make the backend / contract change on a branch in the relevant submodule.
2. PR into that submodule's `develop` (protected → rebase-merge), then bump the root
   submodule pointer on `develop` (see the "Submodule Workflow" section of the root
   `CLAUDE.md`).
3. From the **root** repo, advance the deploy branch to the commit you want live:

   ```bash
   git push origin develop:prod-backend
   # or a specific commit:
   git push origin <sha>:prod-backend
   ```

4. Within ~5 minutes the box builds the backend **from source**, redeploys it with a
   health-gated auto-rollback, and reports the outcome as a GitHub commit status.

### Confirm the deploy (from the Mac — no SSH to the box)

```bash
gh api repos/uzaira0/methodic/commits/prod-backend/status \
  --jq '.state, (.statuses[] | select(.context=="backend-deploy") | "\(.state): \(.description)")'
```

Or just open the `prod-backend` commit on github.com and read its status check.

| `backend-deploy` status | Meaning |
|---|---|
| `pending` | build/deploy in progress on the box |
| `success` | new backend is live and healthy |
| `failure` (build) | build failed — **previous backend still serving, no downtime**; fix and push again |
| `failure` (rolled back) | new image was unhealthy — **auto-rolled back** to the previous image |
| `error` | infra problem (checkout / no rollback image) — needs a look at the box |

A broken commit is attempted **once**; pushing a new commit to `prod-backend` is
required to retry.

---

## 5. What the box does on each deploy (reference)

Box-local poller `/home/opt/chronicle-deploy/backend-deploy-poller.sh` (cron `*/5`):

1. `git fetch` → if `origin/prod-backend` moved, check it out + update backend submodules.
2. Pin the current image as `chronicle-backend:rollback`.
3. `docker compose build chronicle-backend` (from source) → `up -d`.
4. Wait for the container to report healthy (auto-rollback to the pinned image on failure).
5. Run `docker/migrate-tde.sh` (encrypt any newly-added tables at rest) + prune dangling images.
6. Set the GitHub commit status.

No GitHub Actions, no image registry, no inbound network — the box pulls from GitHub
and builds locally. (GitHub Actions CD is intentionally unused: it's billing-walled on
this account.)

---

## Notes

- `develop` may sit ahead of `prod-backend`. That's the intended **dev vs. deployed**
  split — only what you push to `prod-backend` is live.
- The repo on the box bounces to an internal `__deploy` branch during deploys — that's
  expected; don't "fix" it.
- The frontend is not deployed right now. Deploying it later is a separate step.
