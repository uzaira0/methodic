#!/usr/bin/env bash
set -euo pipefail

app_password=$(cat /run/secrets/postgres_app_password)
test -n "$app_password"

psql \
  --username "${POSTGRES_USER:-chronicle}" \
  --dbname "${POSTGRES_DB:-chronicle}" \
  --set ON_ERROR_STOP=1 \
  --set app_password="$app_password" <<'SQL'
SELECT format('ALTER ROLE chronicle_app PASSWORD %L', :'app_password') \gexec
SQL

unset app_password
