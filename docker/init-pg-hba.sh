#!/bin/bash
# Runs once after initdb — writes the production pg_hba.conf into PGDATA.
# On subsequent container restarts this file is already in the volume and
# init scripts do not run, so pg_hba.conf is preserved from this first write.
set -eu

cat > "$PGDATA/pg_hba.conf" << 'HBA'
# PostgreSQL Host-Based Authentication with SSL

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local Unix socket connections (required for pg_isready and initdb)
local   all             all                                     peer

# Localhost connections — SSL optional
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Streaming replication
host    replication     all             172.16.0.0/12           scram-sha-256
hostssl replication     all             172.16.0.0/12           scram-sha-256

# Docker network — SSL required
hostssl all             all             172.16.0.0/12           scram-sha-256
hostssl all             all             10.0.0.0/8              scram-sha-256
hostssl all             all             192.168.0.0/16          scram-sha-256

# All other remote — SSL required
hostssl all             all             0.0.0.0/0               scram-sha-256
hostssl all             all             ::/0                    scram-sha-256
HBA

echo "pg_hba.conf written to $PGDATA/pg_hba.conf"
