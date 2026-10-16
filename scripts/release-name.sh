#!/usr/bin/env bash
# Prints the release name of the checked-out commit, the tag of the images built
# from it: the version of a deploy tag vAAAA.MM.N on that commit (2026.10.1), or
# dev-<commit> for any other commit, dev-<commit>-modified when tracked files differ
# from it. A release name is thus only given to the code its tag holds.
set -euo pipefail
cd "$(dirname "$0")/.."

sha=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "dev-$sha-modified"
  exit 0
fi
tag=$(git tag --points-at HEAD --list 'v[0-9][0-9][0-9][0-9].[0-9][0-9].*' | sort -V | tail -1)
if [ -n "$tag" ]; then echo "${tag#v}"; else echo "dev-$sha"; fi
