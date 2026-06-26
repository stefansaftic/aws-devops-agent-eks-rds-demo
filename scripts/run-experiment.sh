#!/usr/bin/env bash
set -euo pipefail

# Helper to start a FIS experiment by short name.
# Usage:
#   ./scripts/run-experiment.sh <az-disrupt|pod-kill|ebs-pause|attach-hang> [region] [stack]

NAME="${1:-}"
REGION="${2:-us-east-1}"
STACK="${3:-devops-agent-demo}"

case "$NAME" in
  az-disrupt)  KEY=AzDisruptExperimentId ;;
  pod-kill)    KEY=PodKillExperimentId ;;
  ebs-pause)   KEY=EbsPauseIoExperimentId ;;
  attach-hang) KEY=EbsAttachHangExperimentId ;;
  *)
    echo "Usage: $0 <az-disrupt|pod-kill|ebs-pause|attach-hang>" >&2
    exit 1
    ;;
esac

ID="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='${KEY}'].OutputValue" --output text)"

if [[ "$NAME" == "attach-hang" ]]; then
  echo "Reminder: while this experiment runs, scale the StatefulSet to trigger a hung attach:"
  echo "    kubectl scale statefulset postgres --replicas=4"
  echo "    kubectl get pods -w   # watch the new pod stick in ContainerCreating"
fi

echo "==> Starting experiment $NAME (template $ID)"
aws fis start-experiment --region "$REGION" \
  --experiment-template-id "$ID" \
  --query 'experiment.{id:id,status:state.status}' --output table
