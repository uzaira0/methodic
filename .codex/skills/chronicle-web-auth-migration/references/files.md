# Auth Migration File Map

## Frontend Bootstrap

- `chronicle-web/src/index.js`
  - Reads self-hosted token from `config.json`
  - POSTs token to `/chronicle/v3/auth/set-cookie`
  - Initializes config and Redux

## Frontend Auth Utilities

- `chronicle-web/src/core/auth/utils/storeAuthInfo.js`
- `chronicle-web/src/core/auth/utils/getAuthToken.js`
- `chronicle-web/src/core/auth/utils/getAuthTokenExpiration.js`
- `chronicle-web/src/core/auth/utils/isAuthenticated.js`
- `chronicle-web/src/core/auth/utils/clearAuthInfo.js`

## Axios and Config

- `chronicle-web/src/core/config/Configuration.js`
- `chronicle-web/src/core/api/axios/newAxiosInstance.js`
- `chronicle-web/src/core/api/axios/getApiAxiosInstance.js`

## Backend Support

- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/controllers/AuthTokenController.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/pods/servlet/ChronicleServerSecurityPod.kt`
- `chronicle-server/src/main/kotlin/com/openlattice/chronicle/configuration/CookieConfig.kt`

## Tests Commonly Touched

- `chronicle-web/src/core/auth/utils/storeAuthInfo.test.js`
- `chronicle-web/src/core/auth/utils/getAuthToken.test.js`
- `chronicle-web/src/core/auth/utils/getAuthTokenExpiration.test.js`
- `chronicle-web/src/core/auth/utils/isAuthenticated.test.js`
- `chronicle-web/src/core/auth/utils/clearAuthInfo.test.js`
- `chronicle-web/src/core/api/axios/newAxiosInstance.test.js`
- `chronicle-web/src/core/config/Configuration.test.js`

## Typical Drift Patterns

- Tests still expect JWT reads/writes via `localStorage`.
- Tests do not mock `fetch` for cookie endpoint calls.
- Axios tests miss `withCredentials: true`.
- Config tests enforce HTTPS even though self-hosted support now allows `http://` inputs.
