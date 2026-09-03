package main

import rego.v1

# Allow-listed images that use local builds (no tag pinning required)
build_images := {
	"chronicle-backend",
	"chronicle-frontend",
}

# Services allowed to use host networking
host_network_allowed := {
	"fail2ban",
}

# Config file extensions that should be mounted read-only
config_extensions := {".yml", ".yaml", ".toml", ".conf", ".hcl", ".json"}

# Patterns indicating hardcoded secrets in environment values
secret_key_patterns := {"password", "secret", "key"}

# Environment keys that contain a secret-like word but select a mechanism
# rather than carrying credential material.
non_secret_selector_keys := {"pg_tde_key_provider"}

# Explicit disabled sentinels accepted only for the named optional integration.
disabled_secret_sentinel_keys := {"oidc_client_secret"}

# ---------------------------------------------------------------------------
# 1. No `latest` image tags — pin versions (build images are exempt)
# ---------------------------------------------------------------------------
deny contains msg if {
	service := input.services[name]
	image := service.image
	not _is_build_image(image)
	endswith(image, ":latest")
	msg := sprintf("Service '%s' uses ':latest' tag on image '%s'. Pin to a specific version.", [name, image])
}

deny contains msg if {
	service := input.services[name]
	image := service.image
	not _is_build_image(image)
	not contains(image, ":")
	msg := sprintf("Service '%s' has no tag on image '%s'. Pin to a specific version.", [name, image])
}

_is_build_image(image) if {
	some b in build_images
	contains(image, b)
}

# ---------------------------------------------------------------------------
# 2. Memory limits required on all services
# ---------------------------------------------------------------------------
deny contains msg if {
	service := input.services[name]
	not _has_memory_limit(service)
	msg := sprintf("Service '%s' is missing a memory limit (mem_limit or deploy.resources.limits.memory).", [name])
}

_has_memory_limit(service) if {
	service.deploy.resources.limits.memory
}

_has_memory_limit(service) if {
	service.mem_limit
}

# ---------------------------------------------------------------------------
# 3. Health checks required on all services
# ---------------------------------------------------------------------------
deny contains msg if {
	service := input.services[name]
	not _has_healthcheck(service)
	msg := sprintf("Service '%s' is missing a healthcheck.", [name])
}

_has_healthcheck(service) if {
	service.healthcheck
}

# ---------------------------------------------------------------------------
# 4. No host networking (except Fail2ban)
# ---------------------------------------------------------------------------
deny contains msg if {
	service := input.services[name]
	service.network_mode == "host"
	not name in host_network_allowed
	msg := sprintf("Service '%s' uses host networking. This is not allowed (exception: fail2ban).", [name])
}

# ---------------------------------------------------------------------------
# 5. Secret env vars must use ${VAR} substitution, not hardcoded values
# ---------------------------------------------------------------------------

# Handle environment as an object (key: value mapping)
deny contains msg if {
	service := input.services[name]
	env := service.environment[env_key]
	_is_secret_key(lower(env_key))
	is_string(env)
	env != ""
	not _is_accepted_secret_env_value(lower(env_key), env)
	msg := sprintf("Service '%s' has hardcoded secret in environment variable '%s'. Use ${VAR} substitution instead.", [name, env_key])
}

# Handle environment as an array of "KEY=VALUE" strings
deny contains msg if {
	service := input.services[name]
	env_entry := service.environment[_]
	is_string(env_entry)
	contains(env_entry, "=")
	parts := split(env_entry, "=")
	env_key := parts[0]
	_is_secret_key(lower(env_key))
	env_val := substring(env_entry, count(env_key) + 1, -1)
	env_val != ""
	not _is_accepted_secret_env_value(lower(env_key), env_val)
	msg := sprintf("Service '%s' has hardcoded secret in environment variable '%s'. Use ${VAR} substitution instead.", [name, env_key])
}

_is_secret_key(key) if {
	some pattern in secret_key_patterns
	contains(key, pattern)
}

_is_variable_substitution(val) if {
	regex.match(`\$\{[A-Za-z_][A-Za-z0-9_]*[^}]*\}`, val)
}

_is_accepted_secret_env_value(_key, val) if {
	_is_variable_substitution(val)
}

_is_accepted_secret_env_value(key, val) if {
	endswith(key, "_file")
	startswith(trim_space(val), "/run/secrets/")
}

_is_accepted_secret_env_value(key, val) if {
	endswith(key, "_files")
	paths := split(val, ",")
	count(paths) > 0
	every path in paths {
		startswith(trim_space(path), "/run/secrets/")
	}
}

_is_accepted_secret_env_value(key, _val) if {
	key in non_secret_selector_keys
}

_is_accepted_secret_env_value(key, val) if {
	key in disabled_secret_sentinel_keys
	lower(trim_space(val)) == "disabled"
}

# ---------------------------------------------------------------------------
# 6. Config volume mounts should be read-only (:ro)
# ---------------------------------------------------------------------------
deny contains msg if {
	service := input.services[name]
	vol := service.volumes[_]
	is_string(vol)
	_is_config_mount(vol)
	not _is_read_only(vol)
	msg := sprintf("Service '%s' has a config volume mount '%s' that is not read-only. Add ':ro' to the mount.", [name, vol])
}

_is_config_mount(vol) if {
	# Extract the container path (second colon-separated segment)
	parts := split(vol, ":")
	count(parts) >= 2
	container_path := parts[1]
	some ext in config_extensions
	endswith(container_path, ext)
}

_is_read_only(vol) if {
	contains(vol, ":ro")
}

# ---------------------------------------------------------------------------
# 7. no-new-privileges security option recommended
# ---------------------------------------------------------------------------
deny contains msg if {
	service := input.services[name]
	not _has_no_new_privileges(service)
	msg := sprintf("Service '%s' is missing 'no-new-privileges:true' in security_opt. This is recommended to prevent privilege escalation.", [name])
}

_has_no_new_privileges(service) if {
	some opt in service.security_opt
	opt == "no-new-privileges:true"
}

# ---------------------------------------------------------------------------
# 8. PostgreSQL sslmode must not be weaker than verify-full (HIPAA W4)
#
# The prod backend JDBC URL hardcodes sslmode=verify-full (see
# docker/rhizome-docker.yaml.template). POSTGRES_SSL_MODE is retained only for
# non-prod overrides; any compose service that sets it to a weaker mode would
# (re-)introduce a connection that does not verify the server cert + hostname.
# We block disable / allow / prefer / require / verify-ca.
#
# Compose typically sets this as ${POSTGRES_SSL_MODE:-<default>}. We extract the
# literal default after ":-" and evaluate that. When the value is a bare
# interpolation with no literal default (e.g. ${POSTGRES_SSL_MODE}) or is
# absent, there is no literal to judge, so this rule does not fire — the literal
# default in docker/.env.example (verify-full) governs that case, and a CI run
# would surface a too-weak literal default there. We only deny when a weak mode
# is observable as a literal in the compose file itself.
# ---------------------------------------------------------------------------

# Modes weaker than verify-full (everything except verify-full).
weak_sslmodes := {"disable", "allow", "prefer", "require", "verify-ca"}

# environment as an object (key: value mapping)
deny contains msg if {
	service := input.services[name]
	raw := service.environment["POSTGRES_SSL_MODE"]
	is_string(raw)
	mode := _sslmode_literal(raw)
	mode in weak_sslmodes
	msg := sprintf("Service '%s' sets POSTGRES_SSL_MODE='%s', weaker than required 'verify-full'. Use sslmode=verify-full (encrypts + verifies server cert AND hostname); the prod JDBC URL in rhizome-docker.yaml.template already hardcodes it.", [name, mode])
}

# environment as an array of "KEY=VALUE" strings
deny contains msg if {
	service := input.services[name]
	env_entry := service.environment[_]
	is_string(env_entry)
	startswith(env_entry, "POSTGRES_SSL_MODE=")
	raw := substring(env_entry, count("POSTGRES_SSL_MODE="), -1)
	mode := _sslmode_literal(raw)
	mode in weak_sslmodes
	msg := sprintf("Service '%s' sets POSTGRES_SSL_MODE='%s', weaker than required 'verify-full'. Use sslmode=verify-full (encrypts + verifies server cert AND hostname); the prod JDBC URL in rhizome-docker.yaml.template already hardcodes it.", [name, mode])
}

# Resolve the literal sslmode value from a compose env value.
# Handles three forms:
#   "require"                       -> "require"
#   "${POSTGRES_SSL_MODE:-require}" -> "require"  (literal default after ":-")
#   "${POSTGRES_SSL_MODE}"          -> "" (no literal — caller's set lookup misses)

# Bare literal (no ${...} interpolation at all). Lowercased because libpq treats sslmode
# case-insensitively, so "REQUIRE"/"Require" are the same weak mode as "require".
_sslmode_literal(raw) = lower(trim_space(raw)) if {
	not contains(raw, "${")
}

# ${VAR:-default} form — take the literal default after ":-" (also lowercased).
_sslmode_literal(raw) = lower(trim_space(fallback)) if {
	contains(raw, "${")
	contains(raw, ":-")
	after := substring(raw, indexof(raw, ":-") + 2, -1)
	fallback := substring(after, 0, indexof(after, "}"))
}
