#!/usr/bin/env bash
# The development database, prd_mega with the roles and schemas of db/init, as
# DEV_DB in .env says: in Docker (compose.dev-db.yml, 127.0.0.1:55432) or in the
# PostgreSQL server of the machine (127.0.0.1:5432, sudo for its administration).
#
#   scripts/dev-db.sh up       start it; create prd_mega on first use
#   scripts/dev-db.sh status   reachable or not, and the tables per schema
#   scripts/dev-db.sh down     stop it; the data are kept
#   scripts/dev-db.sh reset    delete prd_mega and create it empty (asks first)
set -euo pipefail
. "$(dirname "$0")/dev-env.sh"
cd "$REPO"

compose() { docker compose -f compose.dev-db.yml "$@"; }
as_postgres() { sudo -u postgres psql -X -v ON_ERROR_STOP=1 -q "$@"; }

wait_ready() {
  for _ in $(seq 1 30); do
    pg_isready -q -h 127.0.0.1 -p "$DEV_DB_PORT" && return 0
    sleep 1
  done
  die "aucune base sur 127.0.0.1:$DEV_DB_PORT après 30 s"
}

native_up() {
  pg_isready -q -h 127.0.0.1 -p "$DEV_DB_PORT" || sudo service postgresql start
  wait_ready
  # The pipeline role owns the database, as the image's POSTGRES_USER does; the
  # passwords follow .env on every start.
  as_postgres -v pw="$PIPELINE_DB_PASSWORD" <<'SQL'
SELECT 'CREATE ROLE pipeline LOGIN SUPERUSER' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pipeline') \gexec
ALTER ROLE pipeline PASSWORD :'pw';
SQL
  if [ -z "$(as_postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'prd_mega'")" ]; then
    as_postgres -c "CREATE DATABASE prd_mega OWNER pipeline"
    POSTGRES_USER=pipeline POSTGRES_DB=prd_mega DASHBOARD_DB_PASSWORD="$DASHBOARD_DB_PASSWORD" \
      PGHOST=127.0.0.1 PGPORT="$DEV_DB_PORT" PGPASSWORD="$PIPELINE_DB_PASSWORD" bash db/init/01_schemas.sh
    psql -X -q -v ON_ERROR_STOP=1 "$PIPELINE_DSN" -f db/init/02_external_inputs.sql
    echo "prd_mega créée (db/init)"
  else
    as_postgres -v pw="$DASHBOARD_DB_PASSWORD" -c "ALTER ROLE dashboard PASSWORD :'pw'"
  fi
}

case "${1:-}" in
  up)
    if [ "$DEV_DB" = docker ]; then
      DEV_DB_PORT="$DEV_DB_PORT" compose up -d --wait
    else
      native_up
    fi
    wait_ready
    echo "base de développement ($DEV_DB) : 127.0.0.1:$DEV_DB_PORT, prd_mega"
    ;;
  status)
    if pg_isready -q -h 127.0.0.1 -p "$DEV_DB_PORT"; then
      echo "base de développement ($DEV_DB) : 127.0.0.1:$DEV_DB_PORT, joignable"
      psql -X -q "$PIPELINE_DSN" -c "SELECT table_schema AS schema, count(*) AS tables FROM information_schema.tables
        WHERE table_schema IN ('boost_intermediate', 'boost', 'indicator', 'sboost4') GROUP BY 1 ORDER BY 1"
    else
      echo "base de développement ($DEV_DB) : 127.0.0.1:$DEV_DB_PORT, injoignable (make dev-db-up)"
      exit 1
    fi
    ;;
  down)
    if [ "$DEV_DB" = docker ]; then compose stop; else sudo service postgresql stop; fi
    ;;
  reset)
    if [ "${CONFIRM:-}" != yes ]; then
      read -r -p "Supprimer toutes les données de la base de développement ($DEV_DB) ? [oui/non] " answer
      [ "$answer" = oui ] || die "abandon"
    fi
    if [ "$DEV_DB" = docker ]; then
      compose down -v
    else
      pg_isready -q -h 127.0.0.1 -p "$DEV_DB_PORT" || sudo service postgresql start
      wait_ready
      as_postgres -c "DROP DATABASE IF EXISTS prd_mega WITH (FORCE)" -c "DROP ROLE IF EXISTS dashboard"
    fi
    "$0" up
    ;;
  *)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
