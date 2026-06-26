#!/usr/bin/env bash
set -euo pipefail

# Start the in-cluster CronJob that kills a random Postgres pod every 2 min.
# Runs until ./scripts/stop-pod-killer.sh removes it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="$(aws configure list | awk '/region/ {print $2}')"
REGION="${REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
ECR_PREFIX="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ecr-public"

echo "==> Applying pod-killer CronJob (image prefix: $ECR_PREFIX)"
sed "s|__ECR_PREFIX__|${ECR_PREFIX}|g" "$ROOT/workload/pod-killer.yaml" \
  | kubectl apply -f -

echo
echo "==> Schedule: every 2 minutes (*/2 * * * *)"
echo "    Watch:   kubectl get jobs -w"
echo "    Logs:    kubectl logs -l job-name=<name>"
echo "    Stop:    ./scripts/stop-pod-killer.sh"
