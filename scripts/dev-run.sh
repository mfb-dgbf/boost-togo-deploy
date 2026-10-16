#!/usr/bin/env bash
# Runs the code of the sibling checkouts on the machine, against the development
# database (scripts/dev-db.sh), with the settings compose.yaml gives the containers.
#
#   scripts/dev-run.sh dashboard          rpf-country-dash on 127.0.0.1:DEV_PORT (8050),
#                                         Dash's development server: reloads on every change
#   scripts/dev-run.sh pipeline [STEP...] docker/etl-run.py: every step, or these ones
#   scripts/dev-run.sh steps              the step names
#   scripts/dev-run.sh test               the tests of rpf-country-dash and of this repository
#   scripts/dev-run.sh psql [ARGS]        a SQL session on prd_mega, as pipeline
set -euo pipefail
. "$(dirname "$0")/dev-env.sh"

venv_python() {  # <name>
  [ -x "$DEV/venv-$1/bin/python" ] || die "$DEV/venv-$1 absent : make dev-setup"
  printf '%s' "$DEV/venv-$1/bin/python"
}

pipeline_env() {
  CACHE_REFRESH_TOKEN=$(env_value CACHE_REFRESH_TOKEN)
  GDL_API_TOKEN=$(env_value GDL_API_TOKEN)
  export DB_BACKEND=postgres POSTGRES_DSN="$PIPELINE_DSN" \
    UPSTREAM_DIR="$WORKSPACE" DATA_ROOT="$DEV/etl" OUTPUT_DIR="$DEV/etl/bronze" \
    INPUT_DIR="$DATA_DIR/togo" PEFA_DIR="$DATA_DIR/pefa" COUNTRY_NAME=Togo \
    DASHBOARD_URL="http://127.0.0.1:$DEV_PORT" CACHE_REFRESH_TOKEN GDL_API_TOKEN
  mkdir -p "$DEV/etl/bronze"
}

command=${1:-}
[ $# -eq 0 ] || shift
case "$command" in
  dashboard)
    python=$(venv_python dashboard)
    mkdir -p "$DEV/cache/queries"
    SECRET_KEY=$(env_value SECRET_KEY)
    CACHE_REFRESH_TOKEN=$(env_value CACHE_REFRESH_TOKEN)
    AUTH_ENABLED=$(env_value AUTH_ENABLED 0)
    PUBLIC_ONLY=$(env_value PUBLIC_ONLY False)
    COUNTRIES=$(env_value COUNTRIES Togo)
    DEFAULT_LANGUAGE=$(env_value DEFAULT_LANGUAGE fr)
    END_YEAR=$(env_value END_YEAR 2025)
    export DB_BACKEND=postgres POSTGRES_DSN="$DASHBOARD_DSN" QUERY_CACHE_DIR="$DEV/cache/queries" \
      SECRET_KEY CACHE_REFRESH_TOKEN AUTH_ENABLED PUBLIC_ONLY COUNTRIES DEFAULT_LANGUAGE END_YEAR \
      DEFAULT_ROOT_PATH=/ HOST=127.0.0.1 PORT="$DEV_PORT"
    cd "$WORKSPACE/rpf-country-dash"
    echo "tableau de bord : http://127.0.0.1:$DEV_PORT/ (code de $PWD, base 127.0.0.1:$DEV_DB_PORT)"
    exec "$python" app.py
    ;;
  pipeline)
    python=$(venv_python etl)
    pipeline_env
    args=()
    [ $# -eq 0 ] || args+=(--only "$@")
    # A stopped development dashboard holds no data in memory: emptying its disk
    # cache is enough, and the run's result then depends on the steps only.
    if ! curl -s -o /dev/null --max-time 3 "$DASHBOARD_URL/"; then
      rm -rf "$DEV/cache/queries" && mkdir -p "$DEV/cache/queries"
      echo "tableau de bord de développement arrêté : son cache sur disque est vidé"
      args+=(--no-cache-clear)
    fi
    exec "$python" "$REPO/docker/etl-run.py" "${args[@]}"
    ;;
  steps)
    python=$(venv_python etl)
    pipeline_env
    exec "$python" "$REPO/docker/etl-run.py" --list
    ;;
  test)
    (cd "$WORKSPACE/rpf-country-dash" && "$(venv_python dashboard)" -m unittest discover tests)
    (cd "$REPO" && "$(venv_python etl)" -m unittest discover tests)
    ;;
  psql)
    exec psql -X "$PIPELINE_DSN" "$@"
    ;;
  *)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
