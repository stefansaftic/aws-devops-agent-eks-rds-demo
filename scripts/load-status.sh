#!/usr/bin/env bash
set -euo pipefail

# Quick view of loadgen state. Shows pod placement and the most recent
# TPS / error lines from each loadgen.

echo "==> Pods"
kubectl get pods -l app=loadgen -o wide
echo

echo "==> Recent activity (last TPS sample or error per loadgen)"
for pod in $(kubectl get pods -l app=loadgen -o name); do
  TARGET=$(kubectl get "$pod" -o jsonpath='{.metadata.labels.target}')
  printf "\n--- %s -> %s ---\n" "$pod" "$TARGET"
  kubectl logs --tail=40 "$pod" 2>&1 \
    | grep -E 'progress:|tps =|FATAL|ERROR|loadgen|connection' \
    | tail -10 \
    || echo "(no recent activity)"
done
