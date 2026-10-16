#!/usr/bin/env bash
# Installs what a developer workstation needs to run the BOOST Togo code outside
# Docker, on Ubuntu 22.04 or later (WSL2 included). Run once, as the developer:
# the script calls sudo itself, and dev-setup.sh then creates files the developer
# owns.
#
#   scripts/dev-prerequisites.sh [--native-db]
#
#   make, git, curl, the PostgreSQL client (psql, pg_isready)
#   Python 3.11 with venv, the version of the images (ppa:deadsnakes/ppa when
#   Ubuntu does not carry it, as on 24.04)
#   --native-db   the PostgreSQL server too, for a database outside Docker
#
# Run it directly rather than through make: a stock Ubuntu has no make.
set -euo pipefail

PYTHON=python3.11
NATIVE_DB=0
while [ $# -gt 0 ]; do
  case "$1" in
    --native-db) NATIVE_DB=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (--help)" >&2; exit 2 ;;
  esac
done

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

[ "$(id -u)" -ne 0 ] || die "lancer en utilisateur normal : le script appelle sudo lui-même"
command -v apt-get >/dev/null || die "Ubuntu ou Debian attendu (WSL2 compris)"

step "Paquets système"
sudo apt-get update -q
sudo apt-get install -y -q make git curl ca-certificates postgresql-client
echo "$(make --version | head -1), $(git --version), $(psql --version)"

step "Python 3.11"
if command -v "$PYTHON" >/dev/null && "$PYTHON" -c 'import venv, ensurepip' 2>/dev/null; then
  echo "déjà présent : $($PYTHON --version)"
else
  if ! apt-cache show python3.11-venv >/dev/null 2>&1; then
    sudo apt-get install -y -q software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update -q
  fi
  sudo apt-get install -y -q python3.11 python3.11-venv
  echo "installé : $($PYTHON --version)"
fi

if [ "$NATIVE_DB" = 1 ]; then
  step "Serveur PostgreSQL"
  sudo apt-get install -y -q postgresql
  echo "$(psql --version) ; la base se crée avec : make dev-db-up DEV_DB=native"
fi

step "Docker"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  echo "$(docker --version) : la base de développement peut tourner dans Docker (DEV_DB=docker)"
elif [ "$NATIVE_DB" = 1 ]; then
  echo "absent ou injoignable : sans importance avec la base hors Docker"
else
  echo "absent ou injoignable : relancer avec --native-db, ou installer Docker (deploy/prerequisites.sh)"
fi

step "Suite"
echo "  make dev-setup"
