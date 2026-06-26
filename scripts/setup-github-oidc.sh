#!/usr/bin/env bash
set -euo pipefail

# Bootstrap GitHub Actions -> AWS via OIDC.
# Deploys the github-oidc CFN stack and grants the resulting role
# cluster-admin on the EKS cluster via an Access Entry.
#
# Re-runnable. Safe to run before or after the main demo stack.
#
# Usage:
#   ./scripts/setup-github-oidc.sh [region] [stack-name] [demo-stack-name]

REGION="${1:-us-east-1}"
STACK="${2:-devops-agent-demo-github-oidc}"
DEMO_STACK="${3:-devops-agent-demo}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Region: $REGION  OIDC stack: $STACK  Demo stack: $DEMO_STACK"

# Decide whether THIS stack should own the provider.
#
# Three cases:
#   1. Stack has owned the provider before (CreateOidcProvider=true). Keep
#      it that way — flipping to false would tell CFN to delete the
#      conditional resource it created.
#   2. Stack exists with CreateOidcProvider=false. Some other entity
#      created the provider; we just reused it. Stay false.
#   3. Stack does not exist yet. Owner is whoever the caller wants:
#      - if a provider already exists in the account (e.g. created by
#        another stack/team), reuse it -> false
#      - otherwise create our own -> true
PROVIDER_EXISTS=$(aws iam list-open-id-connect-providers --region "$REGION" \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn" \
  --output text 2>/dev/null || echo "")

STACK_PARAM=$(aws cloudformation describe-stacks --region "$REGION" \
  --stack-name "$STACK" \
  --query "Stacks[0].Parameters[?ParameterKey=='CreateOidcProvider'].ParameterValue" \
  --output text 2>/dev/null || echo "")

if [[ "$STACK_PARAM" == "true" ]]; then
  CREATE_OIDC="true"
  if [[ -n "$PROVIDER_EXISTS" ]]; then
    echo "==> Stack already owns the GitHub OIDC provider — keeping CreateOidcProvider=true"
  else
    echo "==> Stack owns the GitHub OIDC provider but it's missing — recreating (CreateOidcProvider=true)"
  fi
elif [[ "$STACK_PARAM" == "false" ]]; then
  if [[ -n "$PROVIDER_EXISTS" ]]; then
    CREATE_OIDC="false"
    echo "==> External GitHub OIDC provider exists; stack reusing it — keeping CreateOidcProvider=false"
  else
    # Stack thinks it's reusing one, but the external provider has been
    # deleted. Flipping to true makes this stack the new owner.
    CREATE_OIDC="true"
    echo "==> External GitHub OIDC provider has gone missing — taking ownership (CreateOidcProvider=true)"
  fi
else
  # Fresh stack: no prior parameter value to honour.
  if [[ -n "$PROVIDER_EXISTS" ]]; then
    CREATE_OIDC="false"
    echo "==> GitHub OIDC provider already exists in account — reusing (CreateOidcProvider=false)"
  else
    CREATE_OIDC="true"
    echo "==> No GitHub OIDC provider — stack will create one (CreateOidcProvider=true)"
  fi
fi

echo "==> Deploying $STACK"
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK" \
  --template-file "$ROOT/cfn/github-oidc.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides CreateOidcProvider="$CREATE_OIDC"

ROLE_ARN=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text)
echo "==> Role ARN: $ROLE_ARN"

# Grant the GitHub Actions role cluster-admin on the EKS cluster, but only
# if the demo stack already exists. If you run this before deploy.sh, the
# access entry step is a no-op and you should re-run after deploy.sh.
if aws cloudformation describe-stacks --region "$REGION" --stack-name "$DEMO_STACK" >/dev/null 2>&1; then
  CLUSTER=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$DEMO_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='ClusterName'].OutputValue" --output text)
  if [[ -n "$CLUSTER" && "$CLUSTER" != "None" ]]; then
    echo "==> Granting cluster-admin to $ROLE_ARN on cluster $CLUSTER"
    aws eks create-access-entry --region "$REGION" --cluster-name "$CLUSTER" \
      --principal-arn "$ROLE_ARN" >/dev/null 2>&1 || true
    aws eks associate-access-policy --region "$REGION" --cluster-name "$CLUSTER" \
      --principal-arn "$ROLE_ARN" \
      --access-scope type=cluster \
      --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
      >/dev/null
    echo "    done"
  fi
else
  echo "==> Demo stack $DEMO_STACK not found yet — skipping access entry"
  echo "    Re-run this script after deploy.sh completes."
fi

echo
echo "===================================================================="
echo " GitHub Actions OIDC setup complete."
echo
echo " Next steps:"
echo "   1. In your GitHub repo settings, go to:"
echo "        Settings -> Secrets and variables -> Actions -> Variables"
echo "   2. Add a Repository variable:"
echo "        Name:  AWS_ROLE_ARN"
echo "        Value: $ROLE_ARN"
echo "   3. Push a 'scenario/*' branch (or use Run workflow in the UI)"
echo "      to trigger .github/workflows/deploy-scenario.yml"
echo "===================================================================="
