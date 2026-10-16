#!/usr/bin/env bash
# Deploys a release from the Git repository, run in the clone by the account that
# runs the stack:
#
#   scripts/deploy.sh [REF]       REF: a deploy tag vAAAA.MM.N, latest (the highest of
#                                 these tags) or a branch; without REF, the commit
#                                 checked out
#   scripts/deploy.sh --rollback  the release deployed before the current one
#   scripts/deploy.sh --history   the releases deployed from this clone
#
# The database is dumped first (make backup, BACKUP_NAME naming the release). The
# images of the release are built only when missing, so a release deployed before
# starts again from its own images, without network access. Then make up and make
# deploy-check (HTTP 200, a database read by the dashboard's code). When the check
# fails, the release recorded before is started again from its images; the database
# is left as it is, and the dump taken first is named for make restore. Pipeline steps
# are not run here. Each deployment that passes the check is recorded in .releases.
set -euo pipefail
cd "$(dirname "$0")/.."
HISTORY=.releases

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

record() {  # <release> <commit> <ref> <dump>
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M')" "$1" "$2" "$3" "${4:--}" >> "$HISTORY"
}

images_present() {  # <release>
  local image
  for image in dashboard pipeline postgres; do
    docker image inspect "boost-togo/$image:$1" >/dev/null 2>&1 || return 1
  done
}

# The highest deploy tag vAAAA.MM.N known to the clone.
latest_tag() {
  git tag --list 'v[0-9][0-9][0-9][0-9].[0-9][0-9].*' | sort -V | tail -1
}

# Checks out REF: a tag (detached), latest, or a branch brought level with origin.
checkout() {  # <ref>
  local ref=$1
  git fetch -q --tags origin
  if [ "$ref" = latest ]; then
    ref=$(latest_tag)
    [ -n "$ref" ] || die "aucune étiquette vAAAA.MM.N sur origin"
    echo "latest : $ref"
  fi
  if git rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null; then
    git -c advice.detachedHead=false checkout -q --detach "refs/tags/$ref"
  else
    git fetch -q origin "$ref"
    git checkout -q "$ref"
    git merge -q --ff-only "origin/$ref" || die "$ref a des commits locaux absents de origin : mise à jour impossible en avance rapide"
  fi
}

# Starts the checked-out commit with the images of RELEASE (default: its release name),
# building them if missing. A release from .releases is started under the name recorded
# there, the tag of the images it ran with. Each step returns on failure: the caller
# tests the result, where set -e does not apply.
start() {  # [release]
  local release=${1:-$(scripts/release-name.sh)}
  if images_present "$release"; then
    echo "images boost-togo/*:$release présentes : pas de construction"
  else
    make --no-print-directory fetch build RELEASE="$release" || return 1
  fi
  make --no-print-directory up RELEASE="$release" || return 1
  make --no-print-directory deploy-check RELEASE="$release" || return 1
}

dump() {  # <release>: prints the dump's path, or nothing when no database runs
  local name
  docker compose ps --status running --services 2>/dev/null | grep -qx db || return 0
  name="prd_mega-$(date +%Y%m%d-%H%M)-avant-$1"
  make --no-print-directory backup BACKUP_NAME="$name" >&2
  echo "${BACKUP_DIR:-/var/backups/boost-togo}/$name.dump"
}

case "${1:-}" in
  --history)
    [ -s "$HISTORY" ] || { echo "aucune version déployée depuis ce clone"; exit 0; }
    printf 'date              version             commit    ref                 sauvegarde prise avant\n'
    awk -F'\t' '{printf "%-17s %-19s %-9s %-19s %s\n", $1, $2, substr($3, 1, 7), $4, $5}' "$HISTORY"
    exit 0
    ;;
  --rollback)
    [ "$(awk 'END {print NR}' "$HISTORY" 2>/dev/null || echo 0)" -ge 2 ] || die "pas de version précédente dans $HISTORY"
    IFS=$'\t' read -r _ target_release target_commit target_ref _ < <(tail -2 "$HISTORY" | head -1)
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "le clone a des modifications non enregistrées"
    step "Retour à $target_release (${target_commit:0:7}, $target_ref)"
    backup=$(dump "$(scripts/release-name.sh)")
    git -c advice.detachedHead=false checkout -q --detach "$target_commit"
    start "$target_release" || die "$target_release ne répond pas après le retour ; sauvegarde prise avant : ${backup:-aucune}"
    record "$target_release" "$target_commit" "retour" "$backup"
    echo "version en service : $target_release"
    exit 0
    ;;
  -*) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

[ -z "$(git status --porcelain --untracked-files=no)" ] || die "le clone a des modifications non enregistrées"
previous=""
[ -s "$HISTORY" ] && previous=$(tail -1 "$HISTORY")

if [ -n "${1:-}" ]; then
  step "Version demandée : $1"
  checkout "$1"
fi
release=$(scripts/release-name.sh)
commit=$(git rev-parse HEAD)
ref=$(git describe --tags --exact-match --match 'v*' 2>/dev/null || git branch --show-current)
ref=${ref:-${commit:0:7}}
step "Déploiement de $release (${commit:0:7})"
backup=$(dump "$release")
[ -z "$backup" ] || echo "sauvegarde : $backup"

if start; then
  record "$release" "$commit" "$ref" "$backup"
  step "Terminé"
  echo "version en service : $release ; make rollback revient à la précédente"
  exit 0
fi

step "Échec du contrôle : retour à la version précédente"
[ -n "$previous" ] || die "aucune version précédente enregistrée dans $HISTORY ; sauvegarde prise avant : ${backup:-aucune}"
IFS=$'\t' read -r _ previous_release previous_commit _ _ <<<"$previous"
git -c advice.detachedHead=false checkout -q --detach "$previous_commit"
if start "$previous_release"; then
  die "$release n'a pas passé le contrôle ; $previous_release est de nouveau en service. La base n'a pas été modifiée par ce déploiement ; sauvegarde prise avant : ${backup:-aucune}"
fi
die "$release n'a pas passé le contrôle, et $previous_release ne répond pas non plus ; sauvegarde prise avant : ${backup:-aucune} (make restore FILE=…)"
