#!/usr/bin/env bash
set -euo pipefail

# Create one branch per failure scenario. Each branch contains a single
# small, plausible-looking diff to workload/api-app.yaml that breaks the
# API in a specific way once GitHub Actions deploys it.
#
# Run this from a clean working tree on main.
#
# Usage:
#   ./scripts/setup-scenario-branches.sh           # create + commit local branches
#   ./scripts/setup-scenario-branches.sh push      # also push to origin

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PUSH="${1:-}"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit or stash first." >&2
  exit 1
fi

BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> Base branch: $BASE_BRANCH"

apply_sed() {
  local file="$1" expr="$2"
  # Tempfile keeps this portable between BSD and GNU sed.
  sed "$expr" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

create_branch() {
  local name="$1" subject="$2" body="$3"
  shift 3
  echo "==> $name"
  git checkout -B "$name" "$BASE_BRANCH" >/dev/null
  while (($# >= 2)); do
    apply_sed "$1" "$2"
    shift 2
  done
  git add -A
  if git diff --cached --quiet; then
    # An empty diff almost always means a sed pattern is stale (template
    # drift). Fail loudly rather than silently producing an empty branch.
    echo "  ERROR: $name produced no diff — check the sed expressions" >&2
    git checkout "$BASE_BRANCH" >/dev/null
    return 1
  fi
  git commit -m "$subject" -m "$body" >/dev/null
  git checkout "$BASE_BRANCH" >/dev/null
}

# Note: workload/api-app.yaml uses __ECR_PREFIX__ as a placeholder for the
# regional ECR pull-through cache prefix. The deploy.sh / GHA workflow
# substitute it at apply time. Scenario sed patterns target the templated
# form (the file's on-disk state) — substitution happens after.

# 1. Bad image tag — ImagePullBackOff
create_branch "scenario/bad-image-tag" \
  "bump api image to python:3.99-slim" \
  "Pinning a newer Python release for the api-server. CI green locally." \
  workload/api-app.yaml \
  's|image: __ECR_PREFIX__/docker/library/python:3.12-slim|image: __ECR_PREFIX__/docker/library/python:3.99-slim|'

# 2. OOM limits — pod restarts in OOMKilled loop
create_branch "scenario/oom-limits" \
  "tighten api memory limits to reduce node pressure" \
  "Profiling showed steady-state RSS well under 64Mi; this should let us pack more pods per node." \
  workload/api-app.yaml \
  's|memory: 256Mi|memory: 64Mi|' \
  workload/api-app.yaml \
  's|memory: 128Mi|memory: 32Mi|'

# 3. Wrong DB name — /health 503, "database does not exist"
create_branch "scenario/wrong-db-name" \
  "rename db to apidemo_v2 for new schema rollout" \
  "Coordinating with platform team on the v2 rename. RDS already has the new database created." \
  workload/api-app.yaml \
  's|DB_NAME: "apidemo"|DB_NAME: "apidemo_v2"|'

# 4. Bad SQL — /query 500s
create_branch "scenario/bad-sql" \
  "add ORDER BY created_at to /query for stable ordering" \
  "Customers reported jitter in /query results. Sorting by created_at instead of id." \
  workload/api-app.yaml \
  's|ORDER BY id DESC LIMIT 10|ORDER BY created_at DESC LIMIT 10|'

echo
echo "==> Local branches created:"
git branch --list 'scenario/*'

if [[ "$PUSH" == "push" ]]; then
  echo
  echo "==> Pushing scenario branches to origin"
  git push origin -u scenario/bad-image-tag scenario/oom-limits \
    scenario/wrong-db-name scenario/bad-sql
fi

echo
echo "===================================================================="
echo " Scenarios ready. To run a scenario end-to-end:"
echo
echo "   git push origin scenario/bad-image-tag        # if not pushed yet"
echo "   # open a PR from scenario/bad-image-tag to main, merge it"
echo "   # GitHub Actions deploys -> cluster breaks"
echo "   # DevOps Agent investigates -> traces to recent commit"
echo
echo " Or run the workflow manually for any branch via the GitHub UI."
echo "===================================================================="
