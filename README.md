# EKS-FAIL-DEMO

Minimal EKS cluster spread across 3 AZs running three solo Postgres instances
(one per AZ, each with its own EBS PV), a REST API backed by RDS Postgres,
plus pre-built failure experiments designed to produce failures that AWS DevOps
Agent can investigate.

> **Focus:** EKS, RDS, incident investigation and root cause analysis.

## What gets built

```
us-east-1
├── VPC 10.0.0.0/16
│   ├── Public subnet (NAT only)         10.0.0.0/24  AZ-a
│   ├── Private subnet (nodes + pods)    10.0.1.0/24  AZ-a
│   ├── Private subnet (nodes + pods)    10.0.2.0/24  AZ-b
│   ├── Private subnet (nodes + pods)    10.0.3.0/24  AZ-c
│   ├── Single NAT GW (in public-a) for limited internet egress
│   └── VPC endpoints  — ECR(api+dkr), EC2, STS, Logs, S3, SSM, SSMMessages, EC2Messages
├── EKS 1.35 cluster
│   ├── Managed node group (t3.medium × 3, one per AZ)
│   ├── EBS CSI addon (IRSA)
│   ├── Container Insights addon — pod logs + metrics to CloudWatch
│   ├── Postgres StatefulSet (3 replicas, topology spread = one per AZ)
│   └── API server Deployment (3 replicas) → connects to RDS
├── RDS Postgres 16.4 (db.t3.micro, single-AZ, gp3)
│   ├── Enhanced Monitoring + Performance Insights enabled
│   └── Security group: allow 5432 from VPC CIDR
└── 4 FIS experiment templates (EKS failures)
    ├── az-disrupt    — block all traffic to AZ-a's subnet for 5 min
    ├── pod-kill      — delete a random Postgres pod
    ├── ebs-pause     — pause I/O on one Postgres EBS volume for 5 min
    └── attach-hang   — throttle ec2:AttachVolume on the EBS CSI role for 10 min
```

## Prerequisites

- AWS CLI v2 configured for the target account
- `kubectl`
- IAM permissions to create VPC / EKS / IAM / FIS / RDS resources

## Deploy

```bash
./scripts/deploy.sh                       # us-east-1, stack name devops-agent-demo
./scripts/deploy.sh us-east-1 my-stack    # override
```

Takes ~15-20 minutes. Then deploy the API app:

```bash
./scripts/deploy-rds.sh                   # patches RDS endpoint into K8s secret, deploys API + loadgen
```

## Generate load (EKS Postgres)

```bash
./scripts/start-load.sh    # apply 3 loadgen Deployments (pgbench → in-cluster Postgres)
./scripts/load-status.sh   # last TPS sample + recent errors per target
./scripts/stop-load.sh     # remove
```

## RDS API load

The API load generator is deployed automatically by `deploy-rds.sh`. It continuously
hits `/health`, `/query`, `/write` endpoints and logs success/failure to stdout
(visible in CloudWatch Container Insights).

## Demo Scenarios

### EKS Failures (FIS experiments)

```bash
./scripts/run-experiment.sh az-disrupt
./scripts/run-experiment.sh pod-kill
./scripts/run-experiment.sh ebs-pause
./scripts/run-experiment.sh attach-hang
```

| Experiment | What you'll see | Investigation chain |
|---|---|---|
| **az-disrupt** | Postgres pod in AZ-a goes `NotReady`. Cannot reschedule (PV pinned). | Pod events → node `NotReady` → subnet route table / NACL → FIS experiment ARN tag |
| **pod-kill** | Random Postgres pod restarts (~30s recovery). | Pod restart count → kubelet logs → no infra signal → FIS API audit |
| **ebs-pause** | Pod stays `Running` but pg_isready fails. CloudWatch shows VolumeQueueLength spike. | Pod liveness → CW EBS metrics → volume tag → FIS |
| **attach-hang** | Scale `sts postgres --replicas=4` → new pod stuck in `ContainerCreating`. | Pod events → CSI controller logs → CloudTrail throttling → IAM deny policy → FIS |

### RDS Failures (manual scripts)

| Scenario | Script | What you'll see | Investigation chain |
|---|---|---|---|
| **Security group lockout** | `./scripts/rds-break-sg.sh` | API pods return 503. `/health` fails. | Pod logs ("connection timed out") → RDS endpoint DNS resolves → SG has no ingress rule on 5432 |
| **Connection exhaustion** | `./scripts/rds-kill-connections.sh` | API pods intermittently fail with "too many connections". | Pod logs → RDS metrics (DatabaseConnections) → parameter group max_connections=1 |

**Restore:**
```bash
./scripts/rds-fix-sg.sh              # restore security group
./scripts/rds-fix-connections.sh     # restore parameter group + reboot
```

### Recommended demo flow

1. Show healthy state: API returning 200, load generator running clean
2. Run `rds-break-sg.sh` → API starts failing → ask DevOps Agent to investigate
3. Agent traces: pod logs → connection timeout → RDS SG analysis → identifies missing rule
4. Fix it live (`rds-fix-sg.sh`), show recovery
5. Run `az-disrupt` FIS experiment → Postgres pod goes NotReady → DevOps Agent investigates
6. Agent traces: pod events → node condition → subnet disruption → FIS experiment

## Connect to a Postgres pod

```bash
./scripts/connect-postgres.sh        # port-forward to localhost:5432
```

## Shell into a node

```bash
./scripts/ssh-node.sh                # node 0 (via SSM Session Manager)
./scripts/ssh-node.sh 1              # node 1
```

## Tear down

```bash
./scripts/teardown.sh
```

## Files

```
cfn/
  parent.yaml         — orchestrates the nested stacks
  vpc.yaml            — VPC, private subnets, VPC endpoints (no NAT)
  eks.yaml            — cluster, node group, EBS CSI addon, IRSA
  fis.yaml            — FIS role + 4 experiment templates
  rds.yaml            — RDS Postgres instance, subnet group, security group
workload/
  storageclass.yaml   — gp3 default StorageClass
  postgres.yaml       — Postgres StatefulSet (3 replicas, topology-spread)
  loadgen.yaml        — 3× pgbench Deployments, one per Postgres
  fis-rbac.yaml       — ServiceAccount + RBAC for the pod-delete action
  api-app.yaml        — REST API Deployment + Service + Secret (connects to RDS)
  api-loadgen.yaml    — Continuous load generator for the API
scripts/
  deploy.sh             — upload templates, deploy stack, apply manifests
  deploy-rds.sh         — deploy API app with real RDS endpoint
  start-load.sh         — apply pgbench loadgen Deployments
  load-status.sh        — quick TPS/error view of loadgens
  stop-load.sh          — remove loadgen Deployments
  start-pod-killer.sh   — CronJob that kills a random Postgres pod every 2 min
  stop-pod-killer.sh    — remove the pod-killer CronJob
  run-experiment.sh     — start a FIS experiment by short name
  rds-break-sg.sh       — remove RDS security group ingress (simulate connectivity failure)
  rds-fix-sg.sh         — restore RDS security group ingress
  rds-kill-connections.sh — set max_connections=1 (simulate connection exhaustion)
  rds-fix-connections.sh  — restore default parameter group
  connect-postgres.sh   — port-forward Postgres 5432 to localhost
  ssh-node.sh           — SSM Session Manager shell on a node
  pause.sh              — scale nodes to 0 (cost-saver)
  resume.sh             — scale nodes back to 3
  teardown.sh           — clean teardown including orphan EBS sweep
```

## Cost

| State | $/day | What's running |
|---|---|---|
| Running | **~$9.50-10.00** | 3× t3.medium ($3.00) + control plane ($2.40) + 8 interface endpoints ($1.92) + RDS db.t3.micro ($0.50) + NAT GW ($1.08) + Container Insights (~$0.50-1) |
| Paused  | **~$5.90** | control plane + endpoints + RDS + NAT GW (no EC2, no ingest) |
| Down    | $0 | `./scripts/teardown.sh` |
