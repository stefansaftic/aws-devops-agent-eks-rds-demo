#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Removing pod-killer CronJob and its history"
kubectl delete -f "$ROOT/workload/pod-killer.yaml" --ignore-not-found
# Stragglers from completed jobs
kubectl delete jobs -l app.kubernetes.io/name=pod-killer --ignore-not-found || true
