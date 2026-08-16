#!/bin/bash
# Push the public mirror. Development happens on Azure DevOps (origin); GitHub
# is where the source and the releases are published, so it only needs to be
# updated when something is worth publishing.
#
#   scripts/mirror-to-github.sh          # main + tags
#   scripts/mirror-to-github.sh v1.0.0   # …and that tag triggers a release build
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE=github
TAG="${1:-}"

git remote get-url "$REMOTE" >/dev/null 2>&1 || {
    echo "No '$REMOTE' remote. Add it with:"
    echo "  git remote add $REMOTE git@github.com:<user>/neiro.git"
    exit 1
}

# Publishing a branch that is behind origin would put stale source on the
# public side without anyone noticing.
git fetch --quiet origin
if [ -n "$(git rev-list --count "HEAD..origin/main" 2>/dev/null)" ] &&
   [ "$(git rev-list --count "HEAD..origin/main")" != "0" ]; then
    echo "✘ local main is behind origin/main — pull first"
    exit 1
fi

echo "▸ pushing main and tags to $REMOTE"
git push "$REMOTE" main --tags

if [ -n "$TAG" ]; then
    echo "▸ pushing $TAG (this starts the release workflow)"
    git push "$REMOTE" "$TAG"
fi
