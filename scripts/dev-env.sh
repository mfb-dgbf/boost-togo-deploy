# shellcheck shell=bash disable=SC2034
# Settings shared by the dev-*.sh scripts, sourced from them: the workspace, the
# values of .env, and the development database's address. The values a
# container gets from compose.yaml are given here to the code running on the
# machine.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(dirname "$REPO")"
DEV="$WORKSPACE/.boost-dev"

die() { echo "ERREUR : $*" >&2; exit 1; }

[ -r "$REPO/.env" ] || die "$REPO/.env absent ou illisible : make dev-setup"

# The value of KEY in .env (the last line wins), or DEFAULT. A variable already
# set in the environment takes precedence, as with docker compose.
env_value() {  # <key> [default]
  local value
  if [ -n "${!1:-}" ]; then
    printf '%s' "${!1}"
    return
  fi
  value=$(sed -n "s/^$1=//p" "$REPO/.env" | tail -1)
  printf '%s' "${value:-${2:-}}"
}

env_value_or_empty() {  # <key> <default>: as env_value, but a key set to nothing stays empty
  if [ -n "${!1+x}" ]; then
    printf '%s' "${!1}"
  elif grep -q "^$1=" "$REPO/.env"; then
    sed -n "s/^$1=//p" "$REPO/.env" | tail -1
  else
    printf '%s' "$2"
  fi
}

DEV_DB=$(env_value DEV_DB docker)
case "$DEV_DB" in
  docker) DEV_DB_PORT=$(env_value DEV_DB_PORT 55432) ;;
  native) DEV_DB_PORT=$(env_value DEV_DB_PORT 5432) ;;
  *) die "DEV_DB=$DEV_DB dans .env : docker ou native attendu" ;;
esac
DEV_PORT=$(env_value DEV_PORT 8050)
PIPELINE_DB_PASSWORD=$(env_value PIPELINE_DB_PASSWORD)
DASHBOARD_DB_PASSWORD=$(env_value DASHBOARD_DB_PASSWORD)
[ -n "$PIPELINE_DB_PASSWORD" ] && [ -n "$DASHBOARD_DB_PASSWORD" ] \
  || die "PIPELINE_DB_PASSWORD et DASHBOARD_DB_PASSWORD doivent être renseignés dans .env"
PIPELINE_DSN="postgresql://pipeline:$PIPELINE_DB_PASSWORD@127.0.0.1:$DEV_DB_PORT/prd_mega"
DASHBOARD_DSN="postgresql://dashboard:$DASHBOARD_DB_PASSWORD@127.0.0.1:$DEV_DB_PORT/prd_mega"
DATA_DIR=$(env_value INPUT_DIR ./data)
case "$DATA_DIR" in /*) ;; *) DATA_DIR="$REPO/${DATA_DIR#./}" ;; esac
