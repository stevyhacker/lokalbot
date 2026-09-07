#!/bin/bash
# Explicitly overlap trusted master archive preparation with its push CI gates.
# This dispatch creates no tag and publishes no release.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?Usage: Scripts/prepare-release.sh VERSION}"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo 'Commit the candidate first.' >&2; exit 1; }
sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin refs/heads/master | cut -f1)"
[ "$sha" = "$remote_sha" ] || { echo 'Candidate must be the pushed master commit.' >&2; exit 1; }
python3 Scripts/release-preflight.py --candidate --version "$version"
gh workflow run release.yml --ref master --raw-field "version=$version"
printf 'Archive preparation dispatched for %s. Wait for its successful completion and all five push gates before tagging.\n' "$sha"
