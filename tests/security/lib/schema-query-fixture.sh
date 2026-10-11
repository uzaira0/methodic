#!/usr/bin/env bash
# Shared responses for operator schema-verifier transport fixtures.
schema_query_fixture() {
  case "$1" in
    'SELECT 1') printf '1\n' ;;
    *"to_regclass('public.flyway_schema_history')"*) printf 't\n' ;;
    *'FROM flyway_schema_history WHERE NOT success'*) printf '0\n' ;;
    *'MAX(version::int)'*"type = 'BASELINE'"*) printf '0\n' ;;
    *'MAX(version::int)'*) printf '%s\n' "${SCHEMA_EXPECTED_MAX:?}" ;;
    *"type = 'SQL'"*) printf '%s\n' "${SCHEMA_EXPECTED_ROWS:?}" ;;
    *'relrowsecurity'*) printf 'true/true\n' ;;
    *"has_table_privilege('chronicle_app', 'public.mobile_withdrawal_requests', 'INSERT')"*) printf 't\n' ;;
    *"has_table_privilege('chronicle_admin', 'public.restore_continuity_reconciliations', 'SELECT')"*) printf 't\n' ;;
    *'has_table_privilege'*|*'has_schema_privilege'*|*'has_function_privilege'*) printf 'f\n' ;;
    *'FROM pg_policies'*) printf '32\n' ;;
    *'FROM pg_trigger'*) printf '1\n' ;;
    *"to_regclass('public."*) printf 't\n' ;;
    *'FROM pg_constraint'*) printf '%s' "${SCHEMA_FIXTURE_MISSING_FK:-}" ;;
    *'FROM pg_stat_statements'*) printf '1|2|0.500|2|8|0\n' ;;
    'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)'*) printf '[{"Plan":{"Node Type":"Index Scan"},"Execution Time":0.5}]\n' ;;
    *) printf 'unexpected schema query\n' >&2; return 95 ;;
  esac
}
export -f schema_query_fixture
