#!/usr/bin/env bash
set -euo pipefail

# Reset the `deploy` branch to match origin/main, then push.
#
# Use after a demo to clear whatever scenario diff was merged in. main
# is never touched — it stays the clean baseline. Also creates the
# branch on first run if it doesn't exist locally or on origin yet.
#
# Usage:
#   ./scripts/reset-deploy.sh          # reset deploy = main, then push
#   ./scripts/reset-deploy.sh --no-push # reset locally only

PUSH=true
if [[ "${1:-}" == "--no-push" ]]; then
  PUSH=false
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Need a clean tree because we'll switch branches.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash first." >&2
  exit 1
fi

CURRENT="$(git rev-parse --abbrev-ref HEAD)"
echo "==> Fetching origin"
git fetch origin --prune

# Make sure local main is at origin/main before we point deploy at it.
echo "==> Updating local main to origin/main"
git checkout main >/dev/null
git reset --hard origin/main >/dev/null

# Recreate deploy locally from main (works whether or not it existed before).
echo "==> Resetting deploy to main"
git checkout -B deploy main >/dev/null

if [[ "$PUSH" == "true" ]]; then
  # --force-with-lease guards against clobbering work someone else pushed
  # to deploy in the meantime. If you genuinely need to override that,
  # run a plain `git push --force origin deploy` manually.
  echo "==> Force-pushing deploy to origin"
  git push --force-with-lease origin deploy
fi

# Restore whichever branch the user was on, if it still exists.
if [[ "$CURRENT" != "deploy" ]] && git show-ref --verify --quiet "refs/heads/$CURRENT"; then
  git checkout "$CURRENT" >/dev/null
fi

echo
echo "===================================================================="
echo " deploy branch is now at $(git rev-parse --short main) (= main)"
echo
echo " Next demo:"
echo "   1. open a PR from any scenario/* branch into deploy"
echo "   2. merge it -> GitHub Actions deploys -> cluster breaks"
echo "   3. when done, run this script again to reset"
echo "===================================================================="
