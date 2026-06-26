#!/usr/bin/env bash
set -euo pipefail

# Open an SSM Session Manager shell on a node.
# Picks the first node by default; pass an index (0/1/2) to choose.
#
# Requires the SSM Session Manager plugin:
#   https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
#
# Usage: ./scripts/ssh-node.sh [node-index] [region]

INDEX="${1:-0}"
REGION="${2:-us-east-1}"

NODE_NAME="$(kubectl get nodes -o jsonpath='{.items['"$INDEX"'].metadata.name}')"
if [[ -z "$NODE_NAME" ]]; then
  echo "ERROR: no node at index $INDEX" >&2
  kubectl get nodes
  exit 1
fi

# Node name on EKS managed nodes is like ip-10-0-1-23.ec2.internal — the
# providerID has the actual instance ID.
INSTANCE_ID="$(kubectl get node "$NODE_NAME" -o jsonpath='{.spec.providerID}' \
  | sed -E 's|.*/||')"

echo "==> Starting SSM session on node $NODE_NAME ($INSTANCE_ID)"
exec aws ssm start-session --region "$REGION" --target "$INSTANCE_ID"
