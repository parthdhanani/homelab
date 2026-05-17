#!/bin/bash
# Creates databases and users for all services that share PostgreSQL
# Runs on first container start only (docker-entrypoint-initdb.d)
# Idempotent: safe to re-run (uses IF NOT EXISTS)

set -e

create_user_and_db() {
    local db_user="$1" db_pass="$2" db_name="$3" conn_limit="${4:-10}"

    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
        DO \$\$
        BEGIN
            IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${db_user}') THEN
                CREATE ROLE ${db_user} WITH LOGIN PASSWORD '${db_pass}' CONNECTION LIMIT ${conn_limit};
            ELSE
                ALTER ROLE ${db_user} CONNECTION LIMIT ${conn_limit};
            END IF;
        END
        \$\$;
EOSQL

    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -tc \
        "SELECT 1 FROM pg_database WHERE datname = '${db_name}'" | grep -q 1 || \
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres -c \
        "CREATE DATABASE ${db_name} OWNER ${db_user};"
}

# Connection limits:
# - PgBouncer-routed services (moodle, n8n, traxlrs, miniflux): low limit — PgBouncer pools
# - Direct postgres services (forgejo, shlink): higher limit — app connects directly
create_user_and_db "$MOODLE_DB_USER"    "$MOODLE_DB_PASSWORD"    "moodle"    10
create_user_and_db "$N8N_DB_USER"       "$N8N_DB_PASSWORD"       "n8n"       8
create_user_and_db "$TRAXLRS_DB_USER"   "$TRAXLRS_DB_PASSWORD"   "traxlrs"   5
create_user_and_db "$FORGEJO_DB_USER"   "$FORGEJO_DB_PASSWORD"   "forgejo"   50
create_user_and_db "$MINIFLUX_DB_USER"  "$MINIFLUX_DB_PASSWORD"  "miniflux"  5
create_user_and_db "$SHLINK_DB_USER"    "$SHLINK_DB_PASSWORD"    "shlink"    20
create_user_and_db "$UMAMI_DB_USER"       "$UMAMI_DB_PASSWORD"       "umami"       10
create_user_and_db "$WOODPECKER_DB_USER" "$WOODPECKER_DB_PASSWORD" "woodpecker"  8
create_user_and_db "$FERRETDB_DB_USER"  "$FERRETDB_DB_PASSWORD"  "ferretdb"  20
create_user_and_db "$LIBRECHAT_DB_USER" "$LIBRECHAT_DB_PASSWORD" "librechat" 10

echo "All databases initialized."
