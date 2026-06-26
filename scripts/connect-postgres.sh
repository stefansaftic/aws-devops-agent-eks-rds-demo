#!/usr/bin/env bash
set -euo pipefail

# Forward a Postgres pod's 5432 port to localhost so you can connect with
# psql, DBeaver, etc. Picks a Ready pod automatically.
#
# Connection string (after this is running):
#   psql postgresql://postgres:demo@localhost:5432/demo
#
# Usage: ./scripts/connect-postgres.sh [local-port] [pod-index]
#   local-port: defaults to 5432
#   pod-index:  0/1/2 to force a specific replica; default = first Ready

LOCAL_PORT="${1:-5432}"
POD_INDEX="${2:-}"

if [[ -n "$POD_INDEX" ]]; then
  POD="postgres-${POD_INDEX}"
else
  POD="$(kubectl get pods -l app=postgres \
    -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Ready")].status=="True")]}{.metadata.name}{"\n"}{end}' \
    | head -n1)"
fi

if [[ -z "$POD" ]]; then
  echo "ERROR: no Ready Postgres pod found. Try: kubectl get pods" >&2
  exit 1
fi

echo "==> Forwarding ${POD}:5432 -> localhost:${LOCAL_PORT}"
echo "    Connection: psql postgresql://postgres:demo@localhost:${LOCAL_PORT}/demo"
echo "    (Ctrl-C to stop)"
echo
exec kubectl port-forward "pod/${POD}" "${LOCAL_PORT}:5432"
