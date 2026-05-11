#!/bin/bash
# Grant REPLICATION privilege to the chronicle user and create a replication slot.
# Runs once on first initdb (placed in /docker-entrypoint-initdb.d/).
set -eu

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
    ALTER ROLE ${POSTGRES_USER} WITH REPLICATION;

    -- Create a physical replication slot so WAL segments are retained until
    -- the replica has consumed them (prevents WAL recycling during catch-up).
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = 'chronicle_replica_1')
        THEN pg_create_physical_replication_slot('chronicle_replica_1')
        ELSE NULL
    END;
EOSQL

echo "[INFO] REPLICATION privilege granted to ${POSTGRES_USER}; slot chronicle_replica_1 created"
