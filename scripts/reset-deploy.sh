#!/usr/bin/env bash
set -euo pipefail

# Reset the `deploy` branch to match origin/main and rebase every
# scenario/* and feature/* branch on top of the fresh main.
#
# Use before/after a demo. main is never touched — it stays the clean
# baseline. Also creates the deploy branch on first run.
#
# Why also rebase the scenario branches? Whenever main moves (e.g. a
# workflow fix, a new template), the scenario branches drift and their
# PR view starts including unrelated commits and file "deletions" of
# stuff that landed on main after they were last rebased. Baking the
# rebase in here keeps every scenario PR small and focused.
#
# Usage:
#   ./scripts/reset-deploy.sh              # reset deploy + rebase scenarios, push
#   ./scripts/reset-deploy.sh --no-push    # local-only (no origin writes)
#   ./scripts/reset-deploy.sh --deploy-only  # skip scenario rebase (old behaviour)

PUSH=true
REBASE_SCENARIOS=true
for arg in "$@"; do
  case "$arg" in
    --no-push)      PUSH=false ;;
    --deploy-only)  REBASE_SCENARIOS=false ;;
  esac
done

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

# ----- Rebase every scenario/* and feature/* branch onto the new main -----
if [[ "$REBASE_SCENARIOS" == "true" ]]; then
  # Discover scenario/feature branches from origin, so this works even
  # if the local checkout doesn't have them all.
  BRANCHES=$(git ls-remote --heads origin \
    | awk '{print $2}' | sed 's|refs/heads/||' \
    | grep -E '^(scenario|feature)/' || true)

  if [[ -n "$BRANCHES" ]]; then
    echo "==> Rebasing scenario/* + feature/* branches onto main"
    for b in $BRANCHES; do
      echo "  - $b"
      # Create/update the local tracking branch from origin.
      git checkout -B "$b" "origin/$b" >/dev/null 2>&1

      if git rebase origin/main >/tmp/rebase-$$-log 2>&1; then
        # Rebase succeeded. Check the branch is still 1 commit ahead
        # of main -- if it collapses to zero commits, something's off.
        AHEAD=$(git rev-list --count "origin/main..HEAD")
        if [[ "$AHEAD" -eq 0 ]]; then
          echo "      SKIP: rebase collapsed to zero commits (already merged into main?)"
        elif [[ "$PUSH" == "true" ]]; then
          git push --force-with-lease origin "$b" >/dev/null 2>&1 \
            && echo "      pushed ($AHEAD commit(s) ahead of main)" \
            || echo "      WARN: push failed for $b"
        else
          echo "      rebased locally ($AHEAD commit(s) ahead of main)"
        fi
      else
        # Rebase hit a conflict. Abort so the working tree stays clean
        # for the next iteration.
        echo "      CONFLICT: rebase failed, aborting for this branch"
        git rebase --abort >/dev/null 2>&1 || true
      fi
      rm -f /tmp/rebase-$$-log
    done
  fi
fi

# Restore whichever branch the user was on, if it still exists.
git checkout main >/dev/null
if [[ "$CURRENT" != "deploy" ]] && [[ "$CURRENT" != "main" ]] && \
   git show-ref --verify --quiet "refs/heads/$CURRENT"; then
  git checkout "$CURRENT" >/dev/null
fi

echo
echo "===================================================================="
echo " deploy branch is now at $(git rev-parse --short main) (= main)"
if [[ "$REBASE_SCENARIOS" == "true" ]]; then
  echo " scenario/* + feature/* branches rebased onto the same main."
fi
echo
echo " Next demo:"
echo "   1. open a PR from any scenario/* branch into deploy"
echo "   2. merge it -> GitHub Actions deploys -> cluster breaks"
echo "   3. when done, run this script again to reset"
echo "===================================================================="
