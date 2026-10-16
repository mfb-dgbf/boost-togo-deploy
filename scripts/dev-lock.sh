#!/usr/bin/env bash
# Pins in upstream.lock the commits checked out in the sibling repositories: what
# `make build`, `make package` and an installation from Git then deploy.
#
#   scripts/dev-lock.sh [dashboard] [indicators] [boost]    (default: the three)
#   scripts/dev-lock.sh --status    each checkout's branch and commit, the commit
#                                   pinned, and whether the branch is pushed
#
# Each repository must be on a branch with no uncommitted change, and that branch
# must be pushed, at the same commit, to the address upstream.lock names. The
# lock then pins that branch and commit; for the dashboard, the commit's tree; for
# mega-indicators, INDICATORS_PATHS becomes the folders of the notebooks that
# local_runner.notebooks() lists for Togo. `make fetch` checks the result. The
# file is left uncommitted: review it, commit it, push it.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$(dirname "$REPO")"
DEV="$WORKSPACE/.boost-dev"
LOCK="$REPO/upstream.lock"

die() { echo "ERREUR : $*" >&2; exit 1; }

# shellcheck disable=SC1090
. "$LOCK"

if [ "${1:-}" = --status ]; then
  read -r dashboard_pin _ <<<"$DASHBOARD_COMMITS"
  echo "dépôt              branche                              commit   épinglé  sur l'organisation"
  while read -r name url pin; do
    dir="$WORKSPACE/$name"
    if [ ! -d "$dir/.git" ]; then printf '%-18s absent (make dev-setup)\n' "$name"; continue; fi
    branch=$(git -C "$dir" branch --show-current)
    head=$(git -C "$dir" rev-parse HEAD)
    remote=$([ -n "$branch" ] && git ls-remote "$url" "refs/heads/$branch" | cut -f1 || true)
    if [ -z "$branch" ]; then pushed="HEAD détachée"
    elif [ -z "$remote" ]; then pushed="branche absente"
    elif [ "$remote" = "$head" ]; then pushed="à jour"
    else pushed="diffère (${remote:0:7})"; fi
    [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] || pushed="$pushed, modifications non enregistrées"
    printf '%-18s %-36s %-8s %-8s %s\n' "$name" "${branch:--}" "${head:0:7}" "${pin:0:7}" "$pushed"
  done <<EOF
rpf-country-dash $DASHBOARD_URL $dashboard_pin
mega-indicators $INDICATORS_URL $INDICATORS_COMMIT
mega-boost $BOOST_URL $BOOST_COMMIT
EOF
  exit 0
fi

targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(dashboard indicators boost)

set_value() {  # <key> <value>
  python3 - "$LOCK" "$1" "$2" <<'PY'
import re, sys
path, key, value = sys.argv[1:]
text = open(path).read()
text, n = re.subn(rf"^{key}=.*$", lambda m: f"{key}={value}", text, flags=re.M)
if n != 1:
    sys.exit(f"{path}: {n} lines for {key}")
open(path, "w").write(text)
PY
}

# Sets BRANCH and COMMIT for the checkout in <directory>, after the checks above.
checked_out() {  # <directory> <url>
  local dir="$WORKSPACE/$1" remote
  [ -d "$dir/.git" ] || die "$dir absent : make dev-setup"
  BRANCH=$(git -C "$dir" branch --show-current)
  [ -n "$BRANCH" ] || die "$1 n'est sur aucune branche (HEAD détachée) : git switch <branche>"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] \
    || die "$1 a des modifications non enregistrées : git commit, puis git push"
  COMMIT=$(git -C "$dir" rev-parse HEAD)
  remote=$(git ls-remote "$2" "refs/heads/$BRANCH" | cut -f1)
  [ -n "$remote" ] || die "$1 : la branche $BRANCH n'est pas sur $2 : git push -u origin $BRANCH"
  [ "$remote" = "$COMMIT" ] \
    || die "$1 : $BRANCH est à ${COMMIT:0:7} ici et à ${remote:0:7} sur $2 : git push (ou git pull)"
}

# Every checkout is checked before upstream.lock is written: a refusal leaves it as it was.
values=()
for target in "${targets[@]}"; do
  case "$target" in
    dashboard)
      checked_out rpf-country-dash "$DASHBOARD_URL"
      values+=(DASHBOARD_REFS "\"refs/heads/$BRANCH\"" DASHBOARD_COMMITS "\"$COMMIT\""
               DASHBOARD_TREE "$(git -C "$WORKSPACE/rpf-country-dash" rev-parse "$COMMIT^{tree}")")
      echo "rpf-country-dash : $BRANCH ${COMMIT:0:7}"
      ;;
    indicators)
      checked_out mega-indicators "$INDICATORS_URL"
      [ -x "$DEV/venv-etl/bin/python" ] || die "$DEV/venv-etl absent : make dev-setup"
      paths=$(COUNTRY_NAME=Togo DATA_ROOT="$DEV/etl" "$DEV/venv-etl/bin/python" - "$WORKSPACE/mega-indicators" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import local_runner
print(" ".join(sorted({nb.split("/")[0] for nb in local_runner.notebooks() if "/" in nb})))
PY
)
      values+=(INDICATORS_REF "refs/heads/$BRANCH" INDICATORS_COMMIT "$COMMIT" INDICATORS_PATHS "\"$paths\"")
      echo "mega-indicators : $BRANCH ${COMMIT:0:7}, dossiers : $paths"
      ;;
    boost)
      checked_out mega-boost "$BOOST_URL"
      values+=(BOOST_REF "refs/heads/$BRANCH" BOOST_COMMIT "$COMMIT")
      echo "mega-boost : $BRANCH ${COMMIT:0:7}"
      ;;
    *) die "inconnu : $target (dashboard, indicators ou boost)" ;;
  esac
done
for ((i = 0; i < ${#values[@]}; i += 2)); do
  set_value "${values[i]}" "${values[i + 1]}"
done

cd "$REPO"
git --no-pager diff --stat -- upstream.lock
scripts/fetch-upstream.sh
cat <<EOF

upstream.lock est à jour et vérifié. Pour livrer :
  git add upstream.lock && git commit -m "feat: ..." && git push
  puis sur le serveur : le script d'installation depuis Git relancé, ou le paquet de make package
EOF
