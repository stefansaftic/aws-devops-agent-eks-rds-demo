# Cost-optimization scenario — short runbook

Standalone EC2 Postgres serves a steady pgbench-shaped read workload.
A FinOps PR drops the gp3 data volume's provisioned IOPS from 6000 to
the default (3000) "to save ~$20/mo." The volume is now read-IOPS
bound, pgbench TPS halves, and `VolumeQueueLength` climbs above 1.
Service stays up — it just gets slow.

The agent's job: find that the brownout is EBS throttling, trace it to
a CFN stack update, and tie that update to the merged PR.

Open this file in [markdowner](../markdowner/) and click ▶ Run on each
`bash` cell in order.

---

## 0. Pre-demo

Refresh AWS credentials in the markdowner shell first (paste in the
terminal pane below):

```text
export AWS_ACCESS_KEY_ID=…
export AWS_SECRET_ACCESS_KEY=…
export AWS_SESSION_TOKEN=…
```

Verify creds + cluster context:

```bash
aws sts get-caller-identity
aws eks update-kubeconfig --name devops-agent-demo --region us-east-1
```

Make sure `deploy` branch is at `main` (no leftover scenario commits):

```bash
./scripts/reset-deploy.sh
```

---

## 1. Show the healthy baseline

Stack outputs — note `Ec2PostgresDashboardUrl` and `Ec2PostgresDataVolumeId`:

```bash
aws cloudformation describe-stacks --region us-east-1 \
  --stack-name devops-agent-demo \
  --query "Stacks[0].Outputs[?starts_with(OutputKey, 'Ec2Postgres')]" \
  --output table
```

Open the dashboard in a browser:

```bash
open "$(aws cloudformation describe-stacks --region us-east-1 \
  --stack-name devops-agent-demo \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2PostgresDashboardUrl'].OutputValue" \
  --output text)"
```

Capture the data volume ID — used in the metric queries below:

```bash
VOL=$(aws cloudformation describe-stacks --region us-east-1 \
  --stack-name devops-agent-demo \
  --query "Stacks[0].Outputs[?OutputKey=='Ec2PostgresDataVolumeId'].OutputValue" \
  --output text)
echo "VOL=$VOL"
```

Confirm baseline IOPS provisioning (should be 6000 / 250):

```bash
aws ec2 describe-volumes --region us-east-1 --volume-ids "$VOL" \
  --query 'Volumes[0].[VolumeType,Iops,Throughput]' --output table
```

Confirm the in-cluster load generator is publishing TPS:

```bash
kubectl logs -n api-demo -l app=ec2-pg-loadgen --tail=5
```

```text
What you'd say while running these:

  "We have a standalone Postgres on EC2 with a gp3 data volume
   provisioned at 6000 IOPS / 250 MB/s. A read-only workload running
   in the cluster pushes ~2500-3000 TPS through it. CloudWatch shows
   the smoking-gun curve: VolumeReadOps tracks the workload, queue
   length stays near zero. Now we'll merge a FinOps right-sizing PR
   and watch what happens."
```

---

## 2. Merge the PR

```text
In the GitHub UI (do this in the browser — not a Run block):

1. Open https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/compare/deploy...scenario/cost-optimization
2. Click "Create pull request"
3. CRUCIAL: change the base branch dropdown from `main` to `deploy`.
4. Click "Merge pull request" → confirm.
5. Watch the Actions tab — the CFN-update step takes 2-4 min while
   AWS performs the gp3 ModifyVolume in place.
```

---

## 3. Watch the brownout

After ~3 min the volume modification completes. Re-check IOPS — should
be 3000 / 125 now:

```bash
aws ec2 describe-volumes --region us-east-1 --volume-ids "$VOL" \
  --query 'Volumes[0].[VolumeType,Iops,Throughput]' --output table
aws ec2 describe-volumes-modifications --region us-east-1 --volume-ids "$VOL" \
  --query 'VolumesModifications[].[StartTime,ModificationState,TargetIops,TargetThroughput]' \
  --output table
```

pgbench TPS in the loadgen logs has dropped roughly 50%:

```bash
kubectl logs -n api-demo -l app=ec2-pg-loadgen --tail=10
```

Same shape from CloudWatch — the smoking-gun custom metric:

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace EksFailDemo/Pgbench --metric-name Tps \
  --dimensions Name=Target,Value=ec2-postgres \
  --start-time "$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' --output table
```

`VolumeReadOps` plateaus at the new ceiling:

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/EBS --metric-name VolumeReadOps \
  --dimensions Name=VolumeId,Value="$VOL" \
  --start-time "$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Sum \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Sum]' --output table
```

`VolumeQueueLength` rising past 1 confirms throttling rather than just a
workload change:

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/EBS --metric-name VolumeQueueLength \
  --dimensions Name=VolumeId,Value="$VOL" \
  --start-time "$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' --output table
```

The `last-deploy-*` tags on the parent stack point at the merged commit:

```bash
aws cloudformation describe-stacks --region us-east-1 \
  --stack-name devops-agent-demo \
  --query "Stacks[0].Tags[?starts_with(Key, 'last-deploy-')]" --output table
```

---

## 4. Hand off to the agent

```text
Prompt to the agent:

  "Our standalone Postgres on EC2 (instance tagged
   Name=devops-agent-demo-ec2-pg in us-east-1) has gotten slow this
   afternoon. The host is up and the service is responding. Find what's
   wrong."

Investigation chain the agent should follow:

  1. ec2 describe-instances + status checks         →  host is fine
  2. CloudWatch dashboard or get-metric-statistics on AWS/EBS for the
     data volume  →  VolumeReadOps cliff at ~T-5 min, plateau at a
                      flat ~3000 ops/sec; VolumeQueueLength > 1
  3. ec2 describe-volumes                           →  Iops: 3000 (down from 6000)
  4. ec2 describe-volumes-modifications             →  StartTime ≈ T-5 min,
                                                       TargetIops 3000
  5. cloudformation describe-stacks on the parent stack  →  Tags include
     last-deploy-sha / -ref / -gha-run pointing at the
     scenario/cost-optimization PR
  6. Open the PR diff in cfn/parent.yaml: defaults for
     Ec2PostgresDataVolumeIops/Throughput dropped from 6000/250 to
     3000/125 — the gp3 baseline
  7. Root cause: PR right-sized the gp3 volume to baseline IOPS,
     workload is now read-IOPS bound, TPS halved
  8. Fix: revert to 6000 IOPS, or right-size to actual peak demand
```

---

## 5. Recovery

`reset-deploy.sh` resets `deploy` to `main` and force-pushes. The
workflow re-runs with `main`'s `cfn/parent.yaml` (defaults 6000/250),
parent-stack update issues a second `ec2:ModifyVolume`, IOPS go back
up. Takes 2-4 min.

```bash
./scripts/reset-deploy.sh
```

Watch the second modification finish:

```bash
aws ec2 describe-volumes-modifications --region us-east-1 --volume-ids "$VOL" \
  --query 'VolumesModifications[].[StartTime,ModificationState,TargetIops]' \
  --output table
```

pgbench TPS recovers in the loadgen logs:

```bash
kubectl logs -n api-demo -l app=ec2-pg-loadgen --tail=10
```

Final IOPS check (back to 6000 / 250):

```bash
aws ec2 describe-volumes --region us-east-1 --volume-ids "$VOL" \
  --query 'Volumes[0].[VolumeType,Iops,Throughput]' --output table
```
