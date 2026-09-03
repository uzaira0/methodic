#!/usr/bin/env bash
# Enable encryption at rest (Percona pg_tde) and keep it enabled.
#
# Called by `./chronicle up` on every start, not just the first one, because it has to be
# idempotent anyway and because Flyway keeps adding tables. Running it every time is what
# stops the production failure mode where init-db-encryption.sh runs only at database
# initialisation and every table added by a later migration silently stays unencrypted.
#
# WHAT THIS PROTECTS, AND WHAT IT DOES NOT
#   Protects: someone walking off with the disk, or copying the postgres_data volume.
#             The key lives on a separate volume, so a copy of the data alone is useless.
#   Does not protect: anyone with root on this running box. The key is on the box by
#             design -- that is the price of not having a passphrase that can be lost.
#
# ON BEING LOCKED OUT
#   Losing the keyring is unrecoverable. Verified directly: delete the keyring file,
#   restart, and the server answers
#       ERROR: key "..." not found in key provider "..."
#   and pg_dump cannot rescue it either. The protection against that is NOT a second copy
#   of the key -- it is the plain-SQL dumps in ./backups, which are written through the
#   running server and therefore contain no encryption at all. A dump taken while the key
#   was alive restores into any stock Postgres with no pg_tde present (tested against
#   postgres:18.4-alpine: it logs ~40 errors about the missing extension and its key-provider
#   functions, all of which concern objects belonging to pg_tde itself, then restores every
#   table and every row as plain heap).
#
#   That is why `./chronicle up` refuses to enable encryption when backups are disabled.

set -euo pipefail

# Runs INSIDE the db-init service, not on the host, so that `docker compose up -d` performs
# encryption setup with no wrapper script and no access to the Docker socket. It reaches
# Postgres over the compose network and prepares the keyring through the same
# postgres_tde_keyring volume, mounted here as well.
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-chronicle}"
POSTGRES_DB="${POSTGRES_DB:-chronicle}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set}"

KEYRING_DIR="/var/lib/postgresql/tde-keyring"
KEYRING_FILE="${KEYRING_DIR}/chronicle-keyring.per"
PROVIDER="chronicle_keyring"
KEY_NAME="chronicle_key"

# The path pg_tde writes to is the one Postgres sees, which is the same volume mounted at
# the same path in both containers. Keep them identical or the provider records a path that
# does not exist in the server.
psql_run() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql \
    -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 "$@"
}

psql_q() { psql_run -Atc "$1"; }

# Docker creates the keyring volume owned by root, but the server runs as uid 26 (postgres)
# and cannot create the keyring file inside a root-owned directory. This container runs as
# root with CHOWN, so it hands the directory over before pg_tde is asked to write a key.
# 26:26 rather than the name: this image resolves `postgres` to the same uid, but the
# numeric form cannot be wrong if that ever changes.
mkdir -p "$KEYRING_DIR" \
  && chown 26:26 "$KEYRING_DIR" \
  && chmod 700 "$KEYRING_DIR" \
  || { echo "could not prepare $KEYRING_DIR" >&2; exit 1; }

# Postgres reports ready before it accepts connections in some startup paths; the compose
# healthcheck gates this service, but retry briefly rather than fail the whole `up` on a race.
for _ in $(seq 1 30); do
  PGPASSWORD="$POSTGRES_PASSWORD" psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
    -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc 'SELECT 1' >/dev/null 2>&1 && break
  sleep 2
done

psql_q "CREATE EXTENSION IF NOT EXISTS pg_tde;" >/dev/null

# IF NOT EXISTS creates at the image's default_version but does NOT upgrade an extension
# that is already there at an older one. On Percona 18.4-5 the default is pg_tde 2.2, while
# a database restored from a 17-era dump arrives carrying 1.0 -- and stays on 1.0 forever
# without this line. Safe to run unconditionally: when the extension is already current
# Postgres answers NOTICE: version "2.2" ... is already installed and changes nothing.
# Nothing we call was removed between 1.0 and 2.2 (the 1.0->2.0 step only ADDS the vault_v2
# provider functions), so this is a version-record fix rather than a behaviour change.
psql_q "ALTER EXTENSION pg_tde UPDATE;" >/dev/null

# The provider and bootstrap key are created only when no principal key is active. An online
# rotation deliberately gives the active key a timestamped name; forcing KEY_NAME on every
# db-init run would silently undo that rotation after the next `down`/`up` or release upgrade.
psql_run >/dev/null <<SQL
-- pg_tde_list_all_database_key_providers() returns (id, name, type, options): the column
-- is "name", not "provider_name".
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_tde_list_all_database_key_providers()
                 WHERE name = '${PROVIDER}') THEN
    PERFORM pg_tde_add_database_key_provider_file('${PROVIDER}', '${KEYRING_FILE}');
    RAISE NOTICE 'created key provider ${PROVIDER}';
  END IF;
END
\$\$;

-- pg_tde_key_info() always returns exactly one row and fills it with NULLs when no key is
-- set, so only that bootstrap state should select KEY_NAME. Creating the key and adopting an
-- existing one are separate cases, because the key lives
-- in the KEYRING VOLUME while the record of which key this database uses lives in the DATA
-- DIRECTORY. Those are two different volumes and they can legitimately come apart:
-- restoring a dump into a fresh data volume, or rebuilding the cluster while keeping the
-- keyring, leaves a database with no key set and a keyring that already holds
-- '${KEY_NAME}'. Creating unconditionally then fails with
--   ERROR: cannot create key "${KEY_NAME}" because it already exists
-- and db-init exits 3, which stops the whole deployment on a state that is actually fine.
-- Adopting the existing key is also the only correct action there: inventing a second key
-- would leave the old one unreferenced and any data it encrypted unreadable.
DO \$\$
BEGIN
  IF (SELECT key_name FROM pg_tde_key_info()) IS NULL THEN
    BEGIN
      PERFORM pg_tde_create_key_using_database_key_provider('${KEY_NAME}', '${PROVIDER}');
      RAISE NOTICE 'created principal key ${KEY_NAME}';
    EXCEPTION WHEN OTHERS THEN
      -- Narrow on purpose: only "it is already there" is survivable. A missing provider or
      -- an unreadable keyring file must still stop the deployment.
      IF SQLERRM NOT LIKE '%already exists%' THEN
        RAISE;
      END IF;
      RAISE NOTICE 'adopting principal key ${KEY_NAME} already present in ${PROVIDER}';
    END;
    PERFORM pg_tde_set_key_using_database_key_provider('${KEY_NAME}', '${PROVIDER}');
    RAISE NOTICE 'set principal key ${KEY_NAME}';
  ELSE
    RAISE NOTICE 'preserving the active principal key selected by the database';
  END IF;
END
\$\$;
SQL

# Make tde_heap the default for this database so tables created by future Flyway
# migrations are encrypted on creation rather than waiting for the next sweep.
psql_q "ALTER DATABASE \"${POSTGRES_DB}\" SET default_table_access_method = 'tde_heap';" >/dev/null

# Convert anything still on plain heap. ALTER TABLE ... SET ACCESS METHOD rewrites the
# table, so this is the expensive step on first run and a no-op on every run after.
pending=$(psql_q "
  SELECT count(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_am a        ON a.oid = c.relam
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.amname <> 'tde_heap';")

if [[ "$pending" -gt 0 ]]; then
  echo "  encrypting ${pending} table(s) — this rewrites them, so first run takes a while"
  psql_run >/dev/null <<'SQL'
DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_am a        ON a.oid = c.relam
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.amname <> 'tde_heap'
  LOOP
    EXECUTE format('ALTER TABLE public.%I SET ACCESS METHOD tde_heap', t);
  END LOOP;
END
$$;
SQL
fi

enc=$(psql_q "
  SELECT count(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_am a        ON a.oid = c.relam
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.amname = 'tde_heap';")
plain=$(psql_q "
  SELECT count(*) FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_am a        ON a.oid = c.relam
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND a.amname <> 'tde_heap';")

echo "  encryption at rest: ${enc} table(s) encrypted, ${plain} on plain heap"
[[ "$plain" -eq 0 ]] || { echo "  WARNING: ${plain} table(s) could not be converted" >&2; exit 1; }
