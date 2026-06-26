#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Removing load generator"
# kubectl delete only needs metadata to match, so the image placeholder
# being literal is fine here.
kubectl delete -f "$ROOT/workload/loadgen.yaml" --ignore-not-found
