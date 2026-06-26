#!/usr/bin/env bash
set -euo pipefail

# Resume the paused demo. Scales the node group back to 3.
# Usage: ./scripts/resume.sh [region] [stack-name]

REGION="${1:-us-east-1}"
STACK="${2:-devops-agent-demo}"

CLUSTER="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)"

NG="$(aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" \
  --query 'nodegroups[0]' --output text)"

echo "==> Scaling node group $NG back to 3"
aws eks update-nodegroup-config --region "$REGION" \
  --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
  --scaling-config minSize=3,maxSize=6,desiredSize=3 >/dev/null

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" >/dev/null

# kubectl wait --all returns immediately with "no matching resources found"
# if the new nodes haven't registered yet. Wait for them to appear first,
# then wait for Ready.
echo "==> Waiting for nodes to register (up to 5 min)"
for _ in $(seq 1 60); do
  COUNT=$(kubectl get nodes -o name 2>/dev/null | wc -l | tr -d ' ')
  if [ "$COUNT" -ge 3 ]; then
    echo "    $COUNT nodes registered"
    break
  fi
  sleep 5
done

echo "==> Waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=10m

echo "==> Resumed."
kubectl get pods -o wide
