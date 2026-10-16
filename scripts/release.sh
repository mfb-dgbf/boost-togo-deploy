#!/usr/bin/env bash
# Tags a release of the combination upstream.lock pins:
#
#   scripts/release.sh [AAAA.MM.N] [--dry-run]
#
# Without a version, the next one of the month: AAAA.MM after the highest vAAAA.MM.N
# tag on origin, .1 for the month's first. The clone must be clean, on a branch level
# with origin, and upstream.lock must pin one dashboard commit (two commits merged at
# build time are merged in the fork first, so the release is a commit there).
#
#   1. each fork gets the tag togo-<version> on its pinned commit, pushed to the
#      address in upstream.lock; a tag already there on that commit is kept, one on
#      another commit stops the release
#   2. upstream.lock pins those tags (same commits), make fetch checks them, and the
#      change is committed: "release: <version>"
#   3. the deploy tag v<version> goes on that commit, with each fork's commits since
#      its previous togo-* tag when the sibling clones have them, and is pushed with
#      the branch
#
# Pushes go through the GitHub CLI's credentials when it is installed. --dry-run
# shows the version and the steps, and changes nothing.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="$(dirname "$REPO")"
LOCK="$REPO/upstream.lock"
cd "$REPO"

die() { echo "ERREUR : $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

DRY=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) VERSION=$arg ;;
  esac
done

push() {  # <repository directory> <git push arguments...>
  local dir=$1
  shift
  if command -v gh >/dev/null; then
    git -C "$dir" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push "$@"
  else
    git -C "$dir" push "$@"
  fi
}

# The commit a remote ref points to; an annotated tag is peeled to its commit.
remote_commit() {  # <url> <ref>
  git ls-remote "$1" "$2" "$2^{}" \
    | awk -v ref="$2" '$2 == ref "^{}" {peeled = $1} $2 == ref {plain = $1} END {print (peeled != "" ? peeled : plain)}'
}

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

# --- Checks ------------------------------------------------------------------
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "le clone a des modifications non enregistrées"
branch=$(git branch --show-current)
[ -n "$branch" ] || die "le clone n'est sur aucune branche (HEAD détachée)"
git fetch -q --tags origin "$branch"
# shellcheck disable=SC1090
. "$LOCK"
read -r -a dashboard_commits <<<"$DASHBOARD_COMMITS"
[ "${#dashboard_commits[@]}" = 1 ] \
  || die "upstream.lock fusionne ${#dashboard_commits[@]} commits du tableau de bord : les fusionner dans togo/main du fork, puis make dev-lock"

if [ -z "$VERSION" ]; then
  month=$(date +%Y.%m)
  last=$(git tag --list "v$month.*" | sed "s/^v$month\.//" | { grep -E '^[0-9]+$' || true; } | sort -n | tail -1)
  VERSION="$month.$(( ${last:-0} + 1 ))"
fi
[[ "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]] || die "version $VERSION : AAAA.MM.N attendu"
TAG="togo-$VERSION"
step "Version $VERSION (branche $branch)"
# Level with origin, or one commit ahead when that commit is this release's, left
# unpushed by an interrupted run.
if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$branch")" ]; then
  [ "$(git log -1 --format=%s)" = "release: $VERSION" ] && [ "$(git rev-parse HEAD^)" = "$(git rev-parse "origin/$branch")" ] \
    || die "$branch n'est pas au niveau de origin/$branch : git pull, ou git push"
  echo "reprise : le commit « release: $VERSION » n'est pas encore poussé"
fi

existing=$(git rev-parse -q --verify "refs/tags/v$VERSION^{commit}" || true)
lock_on_tags=0
[ "$DASHBOARD_REFS" = "\"refs/tags/$TAG\"" ] || [ "$DASHBOARD_REFS" = "refs/tags/$TAG" ] && lock_on_tags=1
if [ -n "$existing" ] && [ "$existing" != "$(git rev-parse HEAD)" ]; then
  die "v$VERSION existe déjà sur ${existing:0:7}, pas sur HEAD"
fi

# --- 1. Fork tags ----------------------------------------------------------------
notes=""
tag_fork() {  # <name> <url> <commit>
  local name=$1 url=$2 commit=$3 there dir sibling="$WORKSPACE/$1" previous log
  there=$(remote_commit "$url" "refs/tags/$TAG")
  if [ "$there" = "$commit" ]; then
    echo "$name : $TAG déjà sur ${commit:0:7}"
  elif [ -n "$there" ]; then
    die "$name : $TAG existe sur ${there:0:7}, upstream.lock épingle ${commit:0:7}"
  elif [ "$DRY" = 1 ]; then
    echo "$name : $TAG serait créée sur ${commit:0:7} et poussée vers $url"
  else
    if [ -d "$sibling/.git" ] && git -C "$sibling" cat-file -e "$commit^{commit}" 2>/dev/null; then
      dir=$sibling
    else
      dir=$(mktemp -d)
      git init -q "$dir"
      git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    fi
    git -C "$dir" tag -a -m "BOOST Togo $VERSION" "$TAG" "$commit"
    push "$dir" -q "$url" "refs/tags/$TAG"
    echo "$name : $TAG créée sur ${commit:0:7}"
  fi
  # Commits since the fork's previous release tag, from the sibling clone when it has them.
  if [ -d "$sibling/.git" ] && git -C "$sibling" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$sibling" fetch -q "$url" 'refs/tags/togo-*:refs/tags/togo-*' 2>/dev/null || true
    previous=$(git -C "$sibling" tag --list 'togo-*' --merged "$commit" | { grep -vx "$TAG" || true; } | sort -V | tail -1)
    if [ -n "$previous" ] && [ "$(git -C "$sibling" rev-parse "$previous^{commit}")" = "$commit" ]; then
      notes+=$'\n'"$name : inchangé depuis $previous (${commit:0:7})"$'\n'
    elif [ -n "$previous" ]; then
      log=$(git -C "$sibling" log --oneline --no-merges "$previous..$commit" | head -40)
      notes+=$'\n'"$name, depuis $previous :"$'\n'"${log:-  (aucun commit)}"$'\n'
    else
      notes+=$'\n'"$name : première version étiquetée (${commit:0:7})"$'\n'
    fi
  fi
}
# Every fork is checked before any tag is created: a refusal leaves no tag behind.
for spec in "rpf-country-dash $DASHBOARD_URL ${dashboard_commits[0]}" \
            "mega-indicators $INDICATORS_URL $INDICATORS_COMMIT" "mega-boost $BOOST_URL $BOOST_COMMIT"; do
  read -r name url commit <<<"$spec"
  there=$(remote_commit "$url" "refs/tags/$TAG")
  [ -z "$there" ] || [ "$there" = "$commit" ] \
    || die "$name : $TAG existe sur ${there:0:7}, upstream.lock épingle ${commit:0:7} ; choisir une autre version"
done
step "Étiquettes $TAG dans les forks"
tag_fork rpf-country-dash "$DASHBOARD_URL" "${dashboard_commits[0]}"
tag_fork mega-indicators "$INDICATORS_URL" "$INDICATORS_COMMIT"
tag_fork mega-boost "$BOOST_URL" "$BOOST_COMMIT"

# --- 2. upstream.lock on the tags ---------------------------------------------------
step "upstream.lock sur les étiquettes"
if [ "$lock_on_tags" = 1 ]; then
  echo "upstream.lock épingle déjà $TAG"
elif [ "$DRY" = 1 ]; then
  echo "DASHBOARD_REFS, INDICATORS_REF et BOOST_REF passeraient à refs/tags/$TAG (mêmes commits)"
else
  set_value DASHBOARD_REFS "\"refs/tags/$TAG\""
  set_value INDICATORS_REF "refs/tags/$TAG"
  set_value BOOST_REF "refs/tags/$TAG"
  scripts/fetch-upstream.sh
  git add upstream.lock
  git commit -q -m "release: $VERSION" -m "rpf-country-dash ${dashboard_commits[0]:0:7}, mega-indicators ${INDICATORS_COMMIT:0:7}, mega-boost ${BOOST_COMMIT:0:7} ($TAG)"
  echo "commit $(git rev-parse --short HEAD) : release: $VERSION"
fi

# --- 3. Deploy tag -----------------------------------------------------------------
step "Étiquette v$VERSION"
if [ "$DRY" = 1 ]; then
  echo "v$VERSION serait posée sur le commit de upstream.lock et poussée avec $branch"
  [ -z "$notes" ] || printf '%s' "$notes"
  exit 0
fi
if [ -z "$(git rev-parse -q --verify "refs/tags/v$VERSION" || true)" ]; then
  git tag -a "v$VERSION" -m "BOOST Togo $VERSION" -m "${notes:-Commits des forks : clones voisins absents.}"
fi
push "$REPO" -q origin "$branch" "refs/tags/v$VERSION"
echo "v$VERSION poussée sur $(git rev-parse --short HEAD)"
[ -z "$notes" ] || printf '%s' "$notes"
cat <<EOF

Déployer : make deploy REF=v$VERSION (installation depuis Git), ou make package sur cette étiquette.
EOF
