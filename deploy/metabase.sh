#!/usr/bin/env bash
# The optional Metabase service (compose profile metabase), run from the directory
# that holds compose.yaml and .env (installation directory or repository), as the
# account that runs the stack:
#
#   deploy/metabase.sh up       generates the missing .env keys, creates the database
#                               metabase and the roles metabase and metabase_reader,
#                               starts Metabase on METABASE_BIND (127.0.0.1:3000)
#   deploy/metabase.sh down     stops Metabase; its database and roles are kept
#   deploy/metabase.sh status   container state and /api/health
#
# Metabase keeps its questions and dashboards in the database metabase (dumped by
# make backup). It reads prd_mega as metabase_reader: SELECT on the schemas boost and
# indicator, including the tables the pipeline creates later; no access to sboost4,
# which holds the dashboard's login hashes. Every step can be run again.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ -f compose.yaml ] && [ -f .env ] || die "à lancer depuis le répertoire de compose.yaml et .env"
# An installation package has no source to build from: its images are loaded.
no_build=--no-build
[ -f upstream.lock ] && no_build=
compose() { docker compose --profile metabase "$@"; }

env_value() {  # <key>: its value in .env (last line wins)
  sed -n "s/^$1=//p" .env | tail -1
}

# Appends KEY=<generated secret> to .env when the key is absent or empty.
ensure_secret() {  # <key>
  if [ -z "$(env_value "$1")" ]; then
    sed -i.bak "/^$1=/d" .env && rm -f .env.bak
    printf '%s=%s\n' "$1" "$(openssl rand -hex 32)" >> .env
    echo "$1 ajouté à .env (secret généré)"
  fi
}

bind() { local value; value=$(env_value METABASE_BIND); echo "${value:-127.0.0.1:3000}"; }
health() { curl -fsS --max-time 5 "http://$(bind)/api/health" 2>/dev/null; }

case "${1:-}" in
  up)
    step "Secrets (.env)"
    ensure_secret METABASE_DB_PASSWORD
    ensure_secret METABASE_READER_PASSWORD
    ensure_secret METABASE_ENCRYPTION_KEY
    echo "METABASE_ENCRYPTION_KEY déchiffre les connexions enregistrées par Metabase : la garder avec .env"

    step "Base metabase et rôles"
    compose up -d --wait $no_build db
    # Values reach psql through stdin, not its command line.
    compose exec -T db psql -X -q -v ON_ERROR_STOP=1 -U pipeline -d prd_mega <<SQL
\set mb_pw '$(env_value METABASE_DB_PASSWORD)'
\set reader_pw '$(env_value METABASE_READER_PASSWORD)'
SELECT 'CREATE ROLE metabase LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metabase') \gexec
ALTER ROLE metabase PASSWORD :'mb_pw';
SELECT 'CREATE DATABASE metabase OWNER metabase' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'metabase') \gexec
REVOKE CONNECT ON DATABASE metabase FROM PUBLIC;
GRANT CONNECT ON DATABASE metabase TO metabase;
SELECT 'CREATE ROLE metabase_reader LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'metabase_reader') \gexec
ALTER ROLE metabase_reader PASSWORD :'reader_pw';
GRANT CONNECT ON DATABASE prd_mega TO metabase_reader;
GRANT USAGE ON SCHEMA boost, indicator TO metabase_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA boost, indicator TO metabase_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE pipeline IN SCHEMA boost, indicator GRANT SELECT ON TABLES TO metabase_reader;
SQL
    echo "base metabase, rôles metabase et metabase_reader : en place"

    step "Démarrage de Metabase"
    compose up -d --wait $no_build metabase \
      || die "Metabase ne démarre pas : docker compose --profile metabase logs metabase"
    echo "Metabase : $(health) sur http://$(bind)/"
    echo "Première ouverture : créer tout de suite le compte administrateur (la page d'accueil le permet"
    echo "à quiconque l'ouvre avant), puis ajouter la base : PostgreSQL, hôte db, port 5432, base prd_mega,"
    echo "utilisateur metabase_reader, mot de passe METABASE_READER_PASSWORD de .env."
    ;;
  down)
    compose stop metabase
    compose rm -f metabase
    echo "Metabase arrêté ; la base metabase et les rôles sont conservés"
    ;;
  status)
    compose ps metabase --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'
    health && echo || { echo "Metabase ne répond pas"; exit 1; }
    ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
