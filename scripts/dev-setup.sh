#!/usr/bin/env bash
# Sets up the workspace for running the upstream code outside Docker, after
# scripts/dev-prerequisites.sh. Run as the developer, without sudo; safe to run
# again (what is in place is kept).
#
#   scripts/dev-setup.sh [--native-db]
#
# The workspace is the directory that holds this repository:
#   <workspace>/boost-togo-deploy     this repository: .env, data/, upstream.lock
#   <workspace>/rpf-country-dash      the forks of upstream.lock, cloned on the
#   <workspace>/mega-indicators       branch it pins when not there yet
#   <workspace>/mega-boost
#   <workspace>/.boost-dev            Python environments, pipeline downloads,
#                                     the dashboard's query cache
#
# Then: .env (generated secrets) when absent, data/togo and data/pefa, and the
# development database (scripts/dev-db.sh up): in Docker on 127.0.0.1:55432,
# or with --native-db in the PostgreSQL server of the machine on 127.0.0.1:5432.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$(dirname "$REPO")"
DEV="$WORKSPACE/.boost-dev"
PYTHON=python3.11
DB_MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --native-db) DB_MODE=native; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
  esac
done

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" -ne 0 ] || die "lancer en utilisateur normal, sans sudo : les fichiers créés doivent vous appartenir"
command -v "$PYTHON" >/dev/null || die "$PYTHON absent : lancer d'abord scripts/dev-prerequisites.sh"
cd "$REPO"
# shellcheck disable=SC1091
. ./upstream.lock

step "Dépôts voisins ($WORKSPACE)"
clone() {  # <directory> <url> <ref>
  local dir="$WORKSPACE/$1" branch="${3#refs/heads/}"
  if [ -d "$dir/.git" ]; then
    echo "$1 : présent, branche $(git -C "$dir" branch --show-current || true)"
  else
    git clone -q --branch "$branch" "$2" "$dir"
    echo "$1 : cloné, branche $branch"
  fi
}
read -r dashboard_ref _ <<<"$DASHBOARD_REFS"
clone rpf-country-dash "$DASHBOARD_URL" "$dashboard_ref"
clone mega-indicators "$INDICATORS_URL" "$INDICATORS_REF"
clone mega-boost "$BOOST_URL" "$BOOST_REF"

step "Configuration (.env)"
if [ -f .env ]; then
  [ -r .env ] || die ".env n'est pas lisible par $(id -un) : sudo chown $(id -un) .env"
  echo ".env existe déjà : conservé"
else
  (
    umask 077
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        PIPELINE_DB_PASSWORD=|DASHBOARD_DB_PASSWORD=|CACHE_REFRESH_TOKEN=|SECRET_KEY=) echo "${line}$(openssl rand -hex 32)" ;;
        *) echo "$line" ;;
      esac
    done < .env.example > .env
  )
  echo ".env créé avec des secrets générés"
fi
set_env() {  # <key> <value>: replaces or appends the line
  if grep -q "^$1=" .env; then
    sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
current_mode=$(sed -n 's/^DEV_DB=//p' .env | tail -1)
DB_MODE=${DB_MODE:-${current_mode:-docker}}
set_env DEV_DB "$DB_MODE"
echo "base de développement : $DB_MODE"

step "Répertoires d'entrée"
data=$(sed -n 's/^INPUT_DIR=//p' .env | tail -1)
data=${data:-./data}
mkdir -p "$data/togo" "$data/pefa"
ls "$data"/togo/*.xlsx >/dev/null 2>&1 || echo "ATTENTION : aucun classeur .xlsx dans $data/togo : les étapes BOOST échoueront"
ls "$data"/pefa/*.csv >/dev/null 2>&1 || echo "ATTENTION : aucun fichier PEFA dans $data/pefa : l'étape PEFA sera ignorée"

step "Environnements Python ($DEV)"
mkdir -p "$DEV/etl" "$DEV/cache/queries"
venv() {  # <name> <requirements file>
  local dir="$DEV/venv-$1"
  [ -x "$dir/bin/python" ] || "$PYTHON" -m venv "$dir"
  "$dir/bin/python" -m pip install -q --upgrade pip
  "$dir/bin/python" -m pip install -q -r "$2"
  echo "venv-$1 : $("$dir/bin/python" --version), $(wc -l < "$2" | tr -d ' ') lignes de $2"
}
venv dashboard "$WORKSPACE/rpf-country-dash/requirements.txt"
venv etl "$REPO/docker/etl-requirements.txt"

step "Base de développement"
scripts/dev-db.sh up

step "Terminé"
cat <<EOF
  make dev-pipeline STEPS='...'   charger des données (make dev-steps liste les étapes)
  make dev-dashboard              le tableau de bord sur http://127.0.0.1:8050, rechargé à chaque modification
  make dev-test                   les tests
  make help                       toutes les commandes
EOF
