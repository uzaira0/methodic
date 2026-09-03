package main

import rego.v1

base_service := {
	"image": "example.invalid/service:v1.0.0",
	"mem_limit": "128m",
	"healthcheck": {"test": ["CMD", "true"]},
	"security_opt": ["no-new-privileges:true"],
	"environment": {},
	"volumes": [],
}

test_native_compose_memory_limit_is_accepted if {
	findings := deny with input as {"services": {"app": base_service}}
	count(findings) == 0
}

test_missing_memory_limit_is_denied if {
	service := object.remove(base_service, {"mem_limit"})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 1
	"Service 'app' is missing a memory limit (mem_limit or deploy.resources.limits.memory)." in findings
}

test_secret_file_reference_is_accepted if {
	service := object.union(base_service, {
		"environment": {"POSTGRES_PASSWORD_FILE": "/run/secrets/postgres_password"},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 0
}

test_secret_file_list_reference_is_accepted if {
	service := object.union(base_service, {
		"environment": {
			"CHRONICLE_SECURITY_METRICS_PASSWORD_FILES": "/run/secrets/metrics/current,/run/secrets/metrics/previous",
		},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 0
}

test_secret_file_list_outside_secret_mount_is_denied if {
	service := object.union(base_service, {
		"environment": {
			"CHRONICLE_SECURITY_METRICS_PASSWORD_FILES": "/run/secrets/metrics/current,/tmp/metrics-next",
		},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 1
}

test_non_secret_selector_is_accepted if {
	service := object.union(base_service, {
		"environment": {"PG_TDE_KEY_PROVIDER": "file"},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 0
}

test_exact_disabled_sentinel_is_accepted if {
	service := object.union(base_service, {
		"environment": {"OIDC_CLIENT_SECRET": "disabled"},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 0
}

test_plaintext_secret_is_denied if {
	service := object.union(base_service, {
		"environment": {"DATABASE_PASSWORD": "not-a-reference"},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 1
	"Service 'app' has hardcoded secret in environment variable 'DATABASE_PASSWORD'. Use ${VAR} substitution instead." in findings
}

test_secret_file_outside_secret_mount_is_denied if {
	service := object.union(base_service, {
		"environment": {"POSTGRES_PASSWORD_FILE": "/tmp/postgres_password"},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 1
}

test_non_exact_disabled_value_is_denied if {
	service := object.union(base_service, {
		"environment": {"OIDC_CLIENT_SECRET": "disabled-but-not-a-sentinel"},
	})
	findings := deny with input as {"services": {"app": service}}
	count(findings) == 1
}
