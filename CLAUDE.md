# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Full build (all modules)
./gradlew build

# Compile only (fast check)
./gradlew :chronicle-server:compileKotlin :chronicle-api:compileKotlin :rhizome:compileJava

# Create runnable distribution
./gradlew :chronicle-server:installDist

# Run all tests (requires PostgreSQL on localhost:5434, db: chronicle, user: oltest/test)
./gradlew :chronicle-server:test

# Run a single test class
./gradlew :chronicle-server:test --tests "com.openlattice.chronicle.study.StudyTests"

# Run a single test method
./gradlew :chronicle-server:test --tests "com.openlattice.chronicle.study.StudyTests.createStudy"

# Compile tests only (no DB required)
./gradlew :chronicle-server:compileTestKotlin

# OWASP security scan
./gradlew dependencyCheckAll
```

When building inside Docker (no JDK on host):
```bash
docker run --rm -v "$(pwd)":/project -w /project eclipse-temurin:17-jdk bash -c \
  'apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1 && \
   git config --global --add safe.directory "*" && \
   ./gradlew :chronicle-server:compileKotlin --no-daemon -q'
```

Docker image build and deploy:
```bash
docker build -f docker/Dockerfile.backend -t chronicle-backend:latest .
cd docker && docker compose -f docker-compose.traefik.yml -p chronicle up -d chronicle-backend
```

## Architecture

### Module Layout

This is a Gradle multi-project with git submodules:

- **chronicle-api/** — Shared Kotlin data classes (DTOs) with Jakarta Bean Validation. All API interfaces (Retrofit-style) live here. No business logic.
- **chronicle-server/** — Spring MVC REST backend. Controllers, services, Hazelcast mapstores, JDBC storage, scheduled tasks.
- **rhizome/** — Core framework: Jetty embedded server (`JettyLoam`), Spring Security config (`Auth0SecurityPod`), Hazelcast setup, email, metrics, JWT auth.
- **rhizome-client/** — Shared utilities: `ObjectMappers` (Jackson configuration with KotlinModule, GuavaModule, JavaTimeModule), serialization base classes.
- **chronicle-web/** — React frontend (separate submodule).

### Spring Wiring Pattern ("Pods")

Instead of component scanning, the app uses explicit `@Configuration` classes called "Pods" that define `@Bean` methods. The server bootstraps by concatenating pod arrays:

```
ChronicleServer → BaseRhizomeServer → starts Jetty with Spring context
  ├── webPods: ChronicleServerServletsPod, ChronicleServerSecurityPod
  ├── rhizomePods: MapstoresPod, Auth0Pod
  ├── DEFAULT_PODS: HazelcastPod, ConfigurationPod, etc.
  └── chronicleServerPods: ChronicleServerServicesPod, PostgresPod, JdbcPod, etc.
```

Key configuration pods in chronicle-server:
- `ChronicleServerServletsPod` — registers `ChronicleServerMvcPod` and controller component scan
- `ChronicleServerSecurityPod` — Spring Security filter chain, URL authorization rules
- `ChronicleServerServicesPod` — all `@Bean` service definitions
- `ChronicleConfigurationPod` — loads YAML config files into typed config objects

### Request Flow

1. **Jetty** receives HTTP request
2. **Spring Security** filter chain: JWT validation via `CookieOrBearerTokenResolver` → `oauth2ResourceServer().jwt()`
3. **Spring MVC** dispatches to `@RestController` (e.g., `StudyController`)
4. **AOP authorization**: `StudyAuthorizationAspect` checks study-level RBAC permissions via Hazelcast
5. **Service layer** (`*Service` classes) performs business logic
6. **Storage**: JDBC/JDBI for PostgreSQL, Hazelcast `IMap` for cached data (with `MapStore` for lazy-loading from DB)

### Security

- JWT auth (Auth0 or self-hosted HS256). Base config: `Auth0SecurityPod.java` → subclassed by `ChronicleServerSecurityPod.kt`
- `@EnableMethodSecurity(proxyTargetClass = true)` — CGLIB proxies required (concrete types in bean references)
- Mobile endpoints are unauthenticated (HMAC-signed instead); study management endpoints require JWT
- URL patterns: see `ChronicleServerSecurityPod.kt` for the full permitAll/authenticated mapping

### Database

- PostgreSQL 17 via JDBC (no ORM). JDBI 3 for SQL object pattern.
- Hazelcast 5 for distributed caching with `MapStore` implementations for transparent DB persistence
- Tables defined programmatically in `PostgresTablesPod` and `PostgresDataTablesPod`
- Test DB: `localhost:5434`, db `chronicle`, user `oltest`/`test`

### Configuration

YAML files loaded at startup by `ConfigurationService.StaticLoader`:
- `rhizome.yaml` — Hazelcast cluster, PostgreSQL connection pools
- `jetty.yaml` — Jetty server (ports, SSL, gzip, hardening)
- `auth0.yaml` — JWT authentication config
- `chronicle.yaml`, `cors.yaml`, `rate-limit.yaml`, `mail.yaml`

Docker deployment uses `envsubst` on `.yaml.template` files to inject environment variables at container startup (Rhizome doesn't support `${ENV_VAR}` natively).

## Key Conventions

### Kotlin / Jackson

- DTOs are Kotlin data classes. **Do not add `@JsonCreator`** to data classes where all parameters have defaults — the KotlinModule handles them automatically. For delegate/wrapper classes (e.g., `class Foo @JsonCreator(mode = DELEGATING) constructor(items: List<Bar>) : List<Bar> by items`), use `mode = DELEGATING`.
- `ObjectMappers` in rhizome-client registers: KotlinModule, GuavaModule, Jdk8Module, JavaTimeModule, JodaModule, BlackbirdModule.
- `KotlinModule.Builder().build()` — no-arg constructor was removed.

### Spring 6.2 / Jakarta EE 10

- All imports use `jakarta.*` (not `javax.*`). Exceptions: `javax.crypto`, `javax.cache`, `javax.annotation.concurrent` (JSR-305/findbugs).
- Spring Security 6 uses `SecurityFilterChain` beans (not `WebSecurityConfigurerAdapter`).
- Spring MVC 6 has trailing slash matching **disabled** by default — re-enabled in `ChronicleServerMvcPod.kt`.

### Testing

- Integration tests extend `ChronicleServerTests` which starts a real embedded server with Hazelcast + PostgreSQL.
- Pre-configured Retrofit clients: `clientUser1`, `clientUser2`, `clientUser3`, `clientAdmin`.
- Test data factory: `TestDataFactory` in chronicle-server `src/main/kotlin/.../util/tests/`.
- Serialization-only tests (no DB required): extend nothing, use `ObjectMappers.getJsonMapper()` directly.

### Submodule Workflow

Always push submodule branches before pushing the main repo — CI clones submodule commits by SHA. If the SHA doesn't exist on the remote, CI fails.

## Deployment

- Main compose file: `docker/docker-compose.traefik.yml`
- Always use `-p chronicle` flag with docker compose to avoid project name collisions
- Backend port: 40320 (HTTP), 8443 (HTTPS/SSL)
- Frontend served by nginx at `/chronicle`, API at `/chronicle/v3/...`
- Environment variables in `docker/.env` (never committed)
