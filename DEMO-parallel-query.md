# Parallel-query scenario — short runbook

A performance PR "parallelises `/query`" — the handler is refactored
to fan out four concurrent SELECTs against RDS instead of one serial
one. Each shard opens its own psycopg2 connection. Reads like a
straightforward latency optimisation (and it does cut per-request p50
latency).

The catch: connection load per `/query` call goes from 1 to 4. With
3 api-server pods × 3 loadgen replicas hammering `/query` at ~15
req/sec each, the RDS `db.t3.micro` (max_connections ~87) fills up
and starts refusing new connections. The api-server itself looks
healthy — CPU is fine, no restarts, `/health` is 200 — but `/query`
starts returning 500s intermittently.

The agent's job: figure out that neither the pod nor the DB is the
problem in isolation — it's the *connection multiplication* the PR
introduced.

Open this file in [markdowner](../markdowner/) and click ▶ Run on
each `bash` cell in order.

---

## 0. Pre-demo

Refresh AWS credentials (or use the saved profile):

```bash
export AWS_PROFILE=isengard
export AWS_REGION=us-east-1
aws sts get-caller-identity
aws eks update-kubeconfig --name devops-agent-demo --region us-east-1
```

Reset `deploy` to `main` and rebase every scenario branch:

```bash
./scripts/reset-deploy.sh
```

---

## 1. Show the healthy baseline

Open the api-rds dashboard in a browser — you'll watch it change
during the demo:

```bash
aws cloudformation describe-stacks --region us-east-1 \
  --stack-name devops-agent-demo \
  --query "Stacks[0].Outputs[?OutputKey=='ApiRdsDashboardUrl'].OutputValue" \
  --output text
```

Confirm 3 healthy api-server pods:

```bash
kubectl get pods -n api-demo -l app=api-server -o wide
```

Confirm the api-loadgen is producing steady OK output:

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=10
```

Sample the current DatabaseConnections — should be a low, steady
number (roughly 3-6 open):

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=devops-agent-demo-api-db \
  --start-time "$(date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' \
  --output table
```

```text
What you'd say while showing this:

  "3 api-server pods, 3 loadgen pods hitting /health, /query, /write
   at ~45 req/sec cluster-wide. Dashboard shows a healthy baseline:
   3 running pods, 0 restarts, RDS at ~15% CPU, ~5 sustained
   connections, ~10 write IOPS. Now let's merge a performance PR."
```

---

## 2. Merge the PR

```text
In the GitHub UI (do this in the browser — not a Run block):

1. Open https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/compare/deploy...feature/parallel-query
2. Click "Create pull request"
3. CRUCIAL: change the base branch dropdown from `main` to `deploy`.
4. Click "Merge pull request" → confirm.
5. Watch https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/actions
   — the deploy-scenario workflow runs in about 1 minute.
6. Wait 2-3 more minutes for the new pods to roll out and the
   symptom to develop.
```

The PR diff on `workload/api-app.yaml` moves the `/query` handler
from one serial SELECT to four concurrent ones via
`ThreadPoolExecutor(max_workers=4)`, each opening its own
`psycopg2.connect()`. Reads like a good latency optimisation.

---

## 3. Watch the brownout

Sample the api-loadgen output — you'll start seeing intermittent
FAILs on `/query` (`/health` and `/write` still succeed):

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=40 | grep -E 'query|health|write' | tail -30
```

Sample DatabaseConnections — the number should have jumped roughly
4x compared to baseline (~20-40 sustained instead of ~5):

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=devops-agent-demo-api-db \
  --start-time "$(date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' \
  --output table
```

RDS CPU also climbs (each new connection has authentication +
setup cost):

```bash
aws cloudwatch get-metric-statistics --region us-east-1 \
  --namespace AWS/RDS --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=devops-agent-demo-api-db \
  --start-time "$(date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time   "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 60 --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[*].[Timestamp,Average]' \
  --output table
```

Look at what a failing api-server pod is actually seeing — the
error message from psycopg2 is the smoking gun:

```bash
POD=$(kubectl get pods -n api-demo -l app=api-server -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n api-demo "$POD" --tail=30 | tail -20
unset POD
```

You should see lines like `too many connections for role
"demoadmin"` or `FATAL: sorry, too many clients already`.

Deployment annotation stamped by the workflow — this is the bridge
from cluster state to the merged commit:

```bash
kubectl get deploy api-server -n api-demo -o yaml | grep -A3 'annotations:' | head -10
```

On the **api-rds dashboard**:

- **DatabaseConnections**: sustained ~20-40 instead of ~5 (4x jump)
- **RDS CPU**: elevated (~30-50%)
- **RDS Read Latency**: climbs — each `/query` call blocks on 4
  serial `psycopg2.connect()` handshakes when the pool is exhausted
- **api-server pod CPU / restarts / running pods**: unchanged —
  the pods themselves are fine. That's what makes the diagnosis
  interesting.

---

## 4. Hand off to the agent

```text
Prompt to the DevOps Agent (fresh investigation, no prior context):

  "Our /query endpoint on the api-server is returning 500s
   intermittently. /health and /write are fine. Pods are all
   Running and CPU looks OK. RDS is up. Investigate."

Alternative framing that leans into the observability angle:

  "We're seeing a spike in RDS DatabaseConnections since about
   T-5min, and the api-server is returning periodic 500s on /query
   only. Nothing else in the cluster changed. What happened?"

Investigation chain the agent should follow:

  1. kubectl get pods, kubectl top pods       →  everything green
  2. kubectl logs api-server-*                →  "too many
                                                  connections for
                                                  role" from psycopg2
  3. AWS/RDS DatabaseConnections              →  ~4x the baseline,
                                                  starting at T-Xmin
     AWS/RDS CPUUtilization                   →  climbed correspondingly
  4. RDS parameter group max_connections      →  ~87 (default for
                                                  db.t3.micro), being
                                                  hit under normal
                                                  request load now
  5. kubectl get deploy api-server -o yaml    →  annotations point at
                                                  the merged commit:
                                                    eks-fail-demo/git-sha
                                                    eks-fail-demo/git-ref
                                                    eks-fail-demo/gha-run
  6. Open the PR / commit on GitHub. Diff:
        /query switched from one SELECT to four concurrent SELECTs
        via ThreadPoolExecutor(max_workers=4), each opening its own
        psycopg2 connection.
  7. Root cause: the parallelisation quadrupled connection load per
     /query request. With 3 api-server pods × 3 loadgen replicas ×
     ~15 req/sec, /query alone drives ~180 concurrent connections
     against a max_connections of ~87.
  8. Fix options:
       a. Revert the PR (restore serial /query)
       b. Reuse ONE connection across the 4 workers (a proper
          connection pool) instead of opening 4 fresh ones
       c. Raise max_connections on RDS (masks the problem, doesn't
          fix it)
       d. Drop max_workers from 4 to 1-2, or use asyncio without
          multiplying connections
```

---

## 5. Recovery

`reset-deploy.sh` resets `deploy` back to `main` and force-pushes.
The workflow re-runs, re-applies main's api-app.yaml (with the
serial `/query`), and RDS connections drop back to baseline.

```bash
./scripts/reset-deploy.sh
```

Wait ~90 seconds, then confirm all 3 pods steady Ready and error-free:

```bash
kubectl get pods -n api-demo -l app=api-server -o wide
kubectl logs -n api-demo -l app=api-server --tail=10 --prefix=true 2>&1 | tail -20
```

Confirm api-loadgen is back to steady OK on all three endpoints:

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=15
```

Dashboard should recover: **DatabaseConnections** drops back to ~5,
**RDS CPU** back to ~15%, no more `/query` 500s.
