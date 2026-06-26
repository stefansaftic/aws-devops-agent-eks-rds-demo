#!/usr/bin/env bash
set -euo pipefail

# EKS-FAIL-DEMO deploy script.
# Uploads nested CFN templates to S3, deploys the parent stack, then
# applies the k8s workload manifests once the cluster is ready.
#
# Usage:
#   ./scripts/deploy.sh [region] [stack-name]

REGION="${1:-us-east-1}"
STACK="${2:-devops-agent-demo}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${STACK}-templates-${ACCOUNT}-${REGION}"
PREFIX="${STACK}"

echo "==> Account: $ACCOUNT  Region: $REGION  Stack: $STACK"
echo "==> Egress: AWS-only via VPC endpoints (no NAT, no internet)"

echo "==> Ensuring template bucket s3://${BUCKET} exists"
if ! aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled
fi

echo "==> Uploading nested templates"
aws s3 cp "$ROOT/cfn/vpc.yaml" "s3://${BUCKET}/${PREFIX}/vpc.yaml" --region "$REGION"
aws s3 cp "$ROOT/cfn/eks.yaml" "s3://${BUCKET}/${PREFIX}/eks.yaml" --region "$REGION"
aws s3 cp "$ROOT/cfn/fis.yaml" "s3://${BUCKET}/${PREFIX}/fis.yaml" --region "$REGION"

echo "==> Deploying parent stack (this takes ~15-20 min on first run)"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$ROOT/cfn/parent.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      ProjectName="$STACK" \
      TemplateBucket="$BUCKET" \
      TemplatePrefix="$PREFIX"

echo "==> Fetching cluster name"
CLUSTER="$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)"
echo "    Cluster: $CLUSTER"

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER"

# Grant the calling principal cluster-admin via EKS access entries.
# Without this, kubectl will fail with "User is not authorized".
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
echo "==> Granting cluster-admin to $CALLER_ARN"
aws eks create-access-entry --region "$REGION" --cluster-name "$CLUSTER" \
  --principal-arn "$CALLER_ARN" 2>/dev/null || true
aws eks associate-access-policy --region "$REGION" --cluster-name "$CLUSTER" \
  --principal-arn "$CALLER_ARN" \
  --access-scope type=cluster \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  >/dev/null 2>&1 || true

# Grant DevOpsAgentRole-AgentSpace-* roles read-only cluster access via EKS
# Access Entries. Without this, the agent's calls to the kube API are denied
# with "identity is not mapped" / invalid bearer token errors.
#
# We target only -AgentSpace-* roles, not all DevOpsAgentRole-* roles, since
# WebappAdmin/WebappIDC variants belong to other agent stacks and don't need
# cluster access for our investigation flows.
echo "==> Granting cluster-view to DevOpsAgentRole-AgentSpace-* roles"
DEVOPS_AGENT_ARNS="$(aws iam list-roles \
  --query "Roles[?starts_with(RoleName, 'DevOpsAgentRole-AgentSpace-')].Arn" \
  --output text)"
for arn in $DEVOPS_AGENT_ARNS; do
  echo "    -> $arn"
  # Create the access entry. If it already exists (re-running deploy), AWS
  # returns ResourceInUseException — that's fine, we just want it to exist.
  aws eks create-access-entry --region "$REGION" --cluster-name "$CLUSTER" \
    --principal-arn "$arn" >/dev/null 2>&1 \
    || aws eks describe-access-entry --region "$REGION" --cluster-name "$CLUSTER" \
       --principal-arn "$arn" >/dev/null 2>&1 \
    || { echo "    ERROR: failed to create access entry for $arn"; continue; }
  aws eks associate-access-policy --region "$REGION" --cluster-name "$CLUSTER" \
    --principal-arn "$arn" \
    --access-scope type=cluster \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy \
    >/dev/null
done
if [[ -z "$DEVOPS_AGENT_ARNS" ]]; then
  echo "    (none found — skip)"
fi

echo "==> Waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# Manifests use __ECR_PREFIX__ as a placeholder for the regional ECR
# pull-through cache prefix. Substitute before applying.
ECR_PREFIX="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/ecr-public"
echo "==> Applying workload manifests (image prefix: $ECR_PREFIX)"
kubectl apply -f "$ROOT/workload/storageclass.yaml"
kubectl apply -f "$ROOT/workload/fis-rbac.yaml"
sed "s|__ECR_PREFIX__|${ECR_PREFIX}|g" "$ROOT/workload/postgres.yaml" | kubectl apply -f -

echo "==> Waiting for Postgres StatefulSet to roll out"
kubectl rollout status statefulset/postgres --timeout=10m

echo
echo "===================================================================="
echo " Demo cluster is ready."
echo
echo " Pods:"
kubectl get pods -o wide
echo
echo " PVs:"
kubectl get pv
echo
echo " FIS experiment IDs:"
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?contains(OutputKey, 'ExperimentId')]" --output table
echo "===================================================================="
