#!/usr/bin/env python3
"""Static SSO hardening guardrails for the optional local Keycloak broker.

These tests intentionally use only the Python standard library so they can run
in CI before the stack is deployed. They verify the SSO broker stays isolated
from the application database/network and contains only generic provider defaults.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
COMPOSE = ROOT / "docker" / "docker-compose.traefik.yml"
REALM_TEMPLATE = ROOT / "docker" / "keycloak" / "realm-chronicle.json.template"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def check(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def compose_config() -> dict:
    result = subprocess.run(
        [
            "docker",
            "compose",
            "-f",
            str(COMPOSE),
            "--profile",
            "sso",
            "config",
            "--no-env-resolution",
            "--format",
            "json",
        ],
        check=True,
        env={
            **os.environ,
            "DOMAIN": "chronicle.test",
            "POSTGRES_USER": "chronicle",
            "POSTGRES_PASSWORD": "static-test-postgres-password",
            "POSTGRES_DB": "chronicle",
            "JWT_SECRET": "static-test-jwt-secret",
            "CHRONICLE_INTERNAL_WEB_SECRET": "static-test-internal-web-secret-32-bytes",
            "GRAFANA_ADMIN_PASSWORD": "static-test-grafana-password",
            "CHRONICLE_SECURITY_COOKIE_SECURE": "true",
            "HAZELCAST_CLIENT_PASSWORD": "static-test-hazelcast-client-password",
            "HAZELCAST_SERVER_PASSWORD": "static-test-hazelcast-server-password",
            "MOBILE_SIGNING_ENABLED": "true",
            "MOBILE_SIGNING_REQUIRED": "true",
            "CROWDSEC_BOUNCER_API_KEY": "static-test-crowdsec-bouncer-key",
            "CHRONICLE_SECURITY_REQUIRE_MFA": "true",
            "CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED": "false",
        },
        text=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(result.stdout)


def load_realm_template() -> dict:
    rendered = (
        REALM_TEMPLATE.read_text(encoding="utf-8")
        .replace("__REALM__", "chronicle")
        .replace("__CLIENT_ID__", "chronicle-web")
        .replace("__CLIENT_SECRET__", "dummy-secret")
        .replace("__DOMAIN__", "chronicle-screentime-app.chronicle.example.com")
    )
    return json.loads(rendered)


def service_network_names(service: dict) -> set[str]:
    networks = service.get("networks") or {}
    if isinstance(networks, list):
        return set(networks)
    return set(networks)


def service_label_map(service: dict) -> dict[str, str]:
    labels = service.get("labels") or {}
    if isinstance(labels, dict):
        return labels
    parsed: dict[str, str] = {}
    for label in labels:
        if "=" in label:
            key, value = label.split("=", 1)
            parsed[key] = value
    return parsed


def assert_compose_hardening(config: dict) -> None:
    services = config.get("services") or {}
    networks = config.get("networks") or {}
    volumes = config.get("volumes") or {}

    check("keycloak-db-init" not in services, "Keycloak must not mutate the Chronicle app database through an init job")
    check("keycloak" in services, "Keycloak service is missing")
    check("keycloak-postgres" in services, "Dedicated Keycloak Postgres service is missing")

    keycloak = services["keycloak"]
    keycloak_db = services["keycloak-postgres"]
    backend = services.get("chronicle-backend") or {}
    traefik = services.get("traefik") or {}

    keycloak_build = keycloak.get("build") or {}
    check(
        keycloak.get("image") == "chronicle-keycloak:26.6.3-local",
        "Keycloak runtime must use the local optimized Chronicle image",
    )
    check(
        keycloak_build.get("dockerfile", "").endswith("Dockerfile.keycloak"),
        "Keycloak runtime image must be built from docker/Dockerfile.keycloak",
    )
    dockerfile_text = (ROOT / "docker" / "Dockerfile.keycloak").read_text(encoding="utf-8")
    check(
        "quay.io/keycloak/keycloak:26.6.3@sha256:" in dockerfile_text,
        "Dockerfile.keycloak must pin the upstream Keycloak base image by digest",
    )
    check("kc.sh build" in dockerfile_text, "Dockerfile.keycloak must pre-build the optimized Keycloak server")
    keycloak_db_build = keycloak_db.get("build") or {}
    check(
        keycloak_db.get("image") == "chronicle-keycloak-postgres:18.4-local",
        "Keycloak Postgres runtime must use the local patched Chronicle image",
    )
    check(
        keycloak_db_build.get("dockerfile", "").endswith("Dockerfile.keycloak-postgres"),
        "Keycloak Postgres image must be built from docker/Dockerfile.keycloak-postgres",
    )
    postgres_dockerfile = (ROOT / "docker" / "Dockerfile.keycloak-postgres").read_text(encoding="utf-8")
    check(
        "postgres:18.4-alpine@sha256:" in postgres_dockerfile,
        "Dockerfile.keycloak-postgres must pin the upstream Postgres base image by digest",
    )
    check("apk upgrade --no-cache" in postgres_dockerfile, "Dockerfile.keycloak-postgres must apply Alpine security updates")
    check(str(keycloak.get("user")) != "0:0", "Keycloak must not run as root")
    check(keycloak.get("read_only") is True, "Keycloak root filesystem must be read-only")
    check("ALL" in (keycloak.get("cap_drop") or []), "Keycloak must drop all Linux capabilities")
    check(not keycloak.get("cap_add"), "Keycloak must not add Linux capabilities")
    keycloak_startup = "\n".join(
        str(part)
        for part in ((keycloak.get("entrypoint") or []) + (keycloak.get("command") or []))
    )
    check(
        'KEYCLOAK_DEFAULT_IDP" = "upstream-saml"' in keycloak_startup
        and "MFA enforcement cannot use the disabled upstream SAML example" in keycloak_startup,
        "Keycloak startup must reject the disabled SAML example",
    )
    check(
        'CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED" != "true"' in keycloak_startup
        and "production requires verified live current-session MFA IdP proof" in keycloak_startup,
        "Keycloak startup must reject release without live MFA IdP proof",
    )
    check(
        "replace Upstream OIDC client credentials" in keycloak_startup
        and "disabled*" in keycloak_startup,
        "Keycloak startup must reject placeholder or disabled Upstream OIDC credentials",
    )
    check("no-new-privileges:true" in (keycloak.get("security_opt") or []), "Keycloak must set no-new-privileges")
    check(keycloak.get("healthcheck"), "Keycloak must expose a container healthcheck")
    check(
        any(str(mount).split(":", 1)[0] == "/tmp" for mount in (keycloak.get("tmpfs") or [])),
        "Keycloak must use tmpfs for /tmp with a read-only root filesystem",
    )
    keycloak_entrypoint = "\n".join(str(part) for part in (keycloak.get("entrypoint") or []))
    check(
        "identity-provider-redirector" in keycloak_entrypoint,
        "Keycloak startup must configure the browser flow identity-provider redirector",
    )
    check(
        "config.defaultProvider=" in keycloak_entrypoint
        and "KEYCLOAK_DEFAULT_IDP" in keycloak_entrypoint,
        "Keycloak browser flow must default to the configured upstream broker (KEYCLOAK_DEFAULT_IDP)",
    )
    check(
        "config.hideOnLoginPage=true" in keycloak_entrypoint,
        "Keycloak browser flow must hide the local login chooser when redirecting upstream",
    )

    keycloak_networks = service_network_names(keycloak)
    check("chronicle-internal" not in keycloak_networks, "Keycloak must not join the main application database network")
    check("chronicle-backend-bridge" not in keycloak_networks, "Keycloak must not share the backend Traefik bridge")
    check({"chronicle-sso-edge", "chronicle-sso-broker", "chronicle-sso-db"}.issubset(keycloak_networks), "Keycloak SSO networks are incomplete")

    check(service_network_names(keycloak_db) == {"chronicle-sso-db"}, "Keycloak Postgres must only join chronicle-sso-db")
    check("chronicle-sso-broker" in service_network_names(backend), "Chronicle backend must reach Keycloak only through chronicle-sso-broker")
    check("chronicle-sso-edge" in service_network_names(traefik), "Traefik must reach Keycloak only through chronicle-sso-edge")

    for name in ("chronicle-sso-edge", "chronicle-sso-broker", "chronicle-sso-db"):
        check(name in networks, f"{name} network is missing")
        check(networks[name].get("internal") is True, f"{name} network must be internal")

    check("keycloak_data" in volumes, "Keycloak data volume is missing")
    check("keycloak_postgres_data" in volumes, "Keycloak Postgres volume is missing")
    check("keycloak_import" not in volumes, "Legacy Keycloak import volume must not exist")

    keycloak_env = keycloak.get("environment") or {}
    keycloak_db_url = keycloak_env.get("KC_DB_URL", "")
    check("keycloak-postgres:5432" in keycloak_db_url, "Keycloak must use dedicated keycloak-postgres service")
    check("jdbc:postgresql://postgres:5432/" not in keycloak_db_url, "Keycloak must not use the Chronicle app Postgres service")

    check(
        keycloak_env.get("KEYCLOAK_DEFAULT_IDP") == "upstream-oidc",
        "KEYCLOAK_DEFAULT_IDP must select the supported generic upstream OIDC broker",
    )
    backend_env = backend.get("environment") or {}
    check(
        backend_env.get("OIDC_IDP_HINT") == keycloak_env.get("KEYCLOAK_DEFAULT_IDP"),
        "Backend OIDC_IDP_HINT must match the Keycloak default broker (KEYCLOAK_DEFAULT_IDP)",
    )
    backend_command = "\n".join(str(part) for part in (backend.get("command") or []))
    check(
        'OIDC_IDP_HINT" = "upstream-saml"' in backend_command
        and "MFA enforcement cannot use the disabled upstream SAML example" in backend_command,
        "Backend startup must reject the disabled SAML example",
    )
    check(
        'CHRONICLE_SECURITY_MFA_IDP_PROOF_VERIFIED" != "true"' in backend_command
        and "production requires verified live current-session MFA IdP proof" in backend_command,
        "Backend startup must reject release without live MFA IdP proof",
    )

    labels = service_label_map(keycloak)
    check(labels.get("traefik.docker.network") == "chronicle-sso-edge", "Traefik must route Keycloak over chronicle-sso-edge")
    check(
        "PathRegexp(`.*;.*`)" in labels.get("traefik.http.routers.chronicle-keycloak-semicolon-block.rule", ""),
        "Keycloak route must block semicolon path parsing edge cases",
    )
    check(labels.get("traefik.http.middlewares.chronicle-keycloak-forwarded-https.headers.customrequestheaders.X-Forwarded-Proto") == "https", "Keycloak must receive external HTTPS scheme")
    check(labels.get("traefik.http.middlewares.chronicle-keycloak-forwarded-https.headers.customrequestheaders.X-Forwarded-Port") == "443", "Keycloak must receive external HTTPS port")
    check("chronicle-keycloak-ratelimit" in labels.get("traefik.http.routers.chronicle-keycloak.middlewares", ""), "Keycloak route must be rate-limited")


def assert_realm_hardening(realm: dict) -> None:
    providers = {provider["alias"]: provider for provider in realm.get("identityProviders", [])}
    check("upstream-oidc" in providers, "Generic upstream OIDC provider is missing")
    oidc = providers["upstream-oidc"]
    oidc_config = oidc.get("config") or {}

    check(oidc.get("providerId") == "oidc", "upstream-oidc must use the OIDC provider")
    check(oidc.get("enabled") is True, "upstream-oidc must be enabled")
    check(oidc.get("authenticateByDefault") is not True, "default selection must remain redirector-driven")
    check(oidc_config.get("validateSignature") == "true", "upstream tokens must have signatures validated")
    check(oidc_config.get("useJwksUrl") == "true", "upstream signatures must use the configured JWKS")
    check(oidc_config.get("pkceEnabled") == "true", "upstream OIDC must use PKCE")
    check(oidc_config.get("pkceMethod") == "S256", "upstream OIDC must use S256 PKCE")
    for key, placeholder in {
        "clientId": "__UPSTREAM_OIDC_CLIENT_ID__",
        "clientSecret": "__UPSTREAM_OIDC_CLIENT_SECRET__",
        "issuer": "__UPSTREAM_OIDC_ISSUER__",
        "authorizationUrl": "__UPSTREAM_OIDC_AUTH_URL__",
        "tokenUrl": "__UPSTREAM_OIDC_TOKEN_URL__",
        "userInfoUrl": "__UPSTREAM_OIDC_USERINFO_URL__",
        "jwksUrl": "__UPSTREAM_OIDC_JWKS_URL__",
    }.items():
        check(oidc_config.get(key) == placeholder, f"upstream OIDC {key} must be operator supplied")

    saml = providers.get("upstream-saml") or {}
    saml_config = saml.get("config") or {}
    check(saml.get("enabled") is False, "public SAML example must remain disabled")
    check(
        saml_config.get("signingCertificate") == "REPLACE_WITH_UPSTREAM_SAML_SIGNING_CERTIFICATE",
        "public SAML example must not contain an institution signing certificate",
    )
    for key in ("entityId", "singleSignOnServiceUrl", "singleLogoutServiceUrl", "metadataDescriptorUrl"):
        check(
            str(saml_config.get(key, "")).startswith("https://idp.example.org/"),
            f"public SAML example {key} must use a reserved example endpoint",
        )

    default_roles = set(realm.get("defaultRoles") or [])
    check("AuthenticatedUser" in default_roles, "Brokered users must receive the baseline AuthenticatedUser role")
    check("admin" not in default_roles, "Admin must never be a default brokered-user role")

    mappers = {mapper["name"]: mapper for mapper in realm.get("identityProviderMappers", [])}
    for name in (
        "Upstream OIDC email",
        "Upstream OIDC given_name to firstName",
        "Upstream OIDC family_name to lastName",
        "Upstream OIDC preferred_username to username",
        "Upstream OIDC amr passthrough",
    ):
        check(name in mappers, f"Required generic OIDC mapper missing: {name}")
        check(mappers[name].get("identityProviderAlias") == "upstream-oidc", f"{name} must target upstream-oidc")

    amr_idp = mappers.get("Upstream OIDC amr passthrough", {}).get("config") or {}
    check(amr_idp.get("claim") == "amr", "amr passthrough must read the brokered amr claim")
    check(amr_idp.get("user.attribute") == "amr", "amr passthrough must store the amr user attribute")
    check(amr_idp.get("syncMode") == "FORCE", "amr passthrough must refresh every login")

    clients = {client.get("clientId"): client for client in realm.get("clients", [])}
    web = clients.get("chronicle-web") or {}
    client_amr = next(
        (mapper for mapper in (web.get("protocolMappers") or []) if mapper.get("config", {}).get("claim.name") == "amr"),
        None,
    )
    check(client_amr is not None, "chronicle-web must emit an amr claim")
    amr_config = (client_amr or {}).get("config") or {}
    check(amr_config.get("access.token.claim") == "true", "amr must be present in access tokens")
    check(amr_config.get("multivalued") == "true", "amr must remain an RFC 8176 method list")

def main() -> None:
    assert_compose_hardening(compose_config())
    assert_realm_hardening(load_realm_template())
    print("SSO hardening static guardrails passed")


if __name__ == "__main__":
    main()
