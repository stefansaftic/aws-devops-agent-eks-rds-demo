#!/usr/bin/env bash
set -euo pipefail

# Start the pgbench-based load generator. Three Deployments come up,
# one per Postgres instance, each rate-limited to ~50 TPS.
#
# Usage: ./scripts/start-load.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="$(aws configure list | awk '/region/ {print $2}')"
REGION="${REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR_PREFIX="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ecr-public"

echo "==> Applying load generator manifests (image prefix: $ECR_PREFIX)"
sed "s|__ECR_PREFIX__|${ECR_PREFIX}|g" "$ROOT/workload/loadgen.yaml" | kubectl apply -f -

echo "==> Waiting for loadgen pods (this also waits for pgbench schema init, ~30s first time)"
kubectl rollout status deploy/loadgen-0 --timeout=3m
kubectl rollout status deploy/loadgen-1 --timeout=3m
kubectl rollout status deploy/loadgen-2 --timeout=3m

echo
echo "==> Load running. Useful commands:"
echo "    ./scripts/load-status.sh                       # quick view"
echo "    kubectl logs -l app=loadgen -f --max-log-requests=3 --tail=20"
echo "    ./scripts/stop-load.sh                          # stop"
