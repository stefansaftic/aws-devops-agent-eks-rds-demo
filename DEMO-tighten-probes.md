# Tighten-probes scenario — short runbook

An SRE-flavoured PR to `workload/api-app.yaml` "tightens" the api-server
readiness/liveness probes for faster failure detection, adjusting
`periodSeconds`, `timeoutSeconds`, and `failureThreshold`. Reads like a
post-incident hardening PR.

The catch: `/health` does a real Postgres roundtrip against RDS, which
under normal jitter occasionally exceeds the new 1-second timeout. So
individual healthy pods intermittently flip to NotReady, get killed,
restart. Client traffic sees periodic 5xx / timeouts even though the
DB is fine.

The agent's job: figure out that this isn't RDS or a resource crunch,
it's a probe contract that's tighter than what `/health` can meet.

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

Or, if you saved them as an isengard profile earlier:

```bash
export AWS_PROFILE=isengard
export AWS_REGION=us-east-1
```

Verify creds + cluster context:

```bash
aws sts get-caller-identity
aws eks update-kubeconfig --name devops-agent-demo --region us-east-1
```

Make sure `deploy` is at `main` and every scenario branch is rebased
onto the same tip (no drifted PRs):

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

Confirm the api-loadgen is producing steady OK output (~45 req/sec
across 3 replicas):

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=10
```

```text
What you'd say while showing this:

  "Three api-server pods across three AZs, backed by RDS Postgres.
   A load generator is hitting /health, /query, /write in a tight
   loop -- 45 req/sec cluster-wide -- and everything is 200 OK.
   Dashboard shows the healthy baseline: 3 running pods, 0 restarts,
   RDS at ~15% CPU, ~5 sustained connections, ~10 write IOPS.
   Now let's merge a PR."
```

---

## 2. Merge the PR

```text
In the GitHub UI (do this in the browser — not a Run block):

1. Open https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/compare/deploy...feature/tighten-probes
2. Click "Create pull request"
3. CRUCIAL: change the base branch dropdown from `main` to `deploy`.
   If you leave it on main, the merge pollutes main and the workflow
   won't fire.
4. Click "Merge pull request" → confirm.
5. Watch https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/actions
   — the deploy-scenario workflow runs in about 1 minute.
6. Wait 2-3 more minutes for symptoms to appear: pods will start
   flapping between Ready and NotReady.
```

The PR diff is 4 numbers on `workload/api-app.yaml`:

```text
readinessProbe:
  periodSeconds: 10 -> 2
  failureThreshold: 3 (default) -> 1
  timeoutSeconds: 1 (added, explicit)
livenessProbe:
  periodSeconds: 15 -> 3
  failureThreshold: 3 (default) -> 1
  timeoutSeconds: 1 (added, explicit)
```

Reads like a plausible post-incident hardening.

---

## 3. Watch the brownout

Snapshot pod state — the Ready column will start flipping between
`1/1` and `0/1`:

```bash
kubectl get pods -n api-demo -l app=api-server -o wide
```

Look at the api-loadgen output — periodic FAILs will appear:

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=30
```

Pick a flapping pod and see why the probe is failing:

```bash
POD=$(kubectl get pods -n api-demo -l app=api-server -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n api-demo "$POD" | tail -30
unset POD
```

Look for lines like:

```text
Readiness probe failed: Get "http://.../health": context deadline exceeded
Liveness probe failed:  Get "http://.../health": context deadline exceeded
```

The Deployment is annotated with the merged commit — this is the
bridge from cluster state to git history:

```bash
kubectl get deploy api-server -n api-demo -o yaml | grep -A3 'annotations:' | head -10
```

Endpoints for the api-server Service will be flapping too — count
between 2 and 3:

```bash
kubectl get endpoints api-server -n api-demo
```

On the **api-rds dashboard** (which you have open in a browser):

- **Running pods** widget: dips below 3, flaps back up
- **Container restarts**: climbs from 0
- **api-server pod CPU**: unchanged (the DB queries themselves are fine)
- **RDS DatabaseConnections / CPU / IOPS**: barely change (RDS is not
  the problem — the *contract* between the probe and `/health` is)

---

## 4. Hand off to the agent

```text
Prompt to the DevOps Agent (fresh investigation, no prior context):

  "Users report that our API is flaky — some requests succeed, others
   fail with 5xx or time out. The pods are up, no CrashLoops, no
   recent config changes on our side that we're aware of. RDS looks
   fine. Investigate what's causing the intermittent failures."

Alternative (slightly more scoped) framing:

  "Our api-server in the api-demo namespace is intermittently
   degraded — loadgen is seeing periodic failures but the pods
   aren't crashing. Take a look and tell me what's happening."

Investigation chain the agent should follow:

  1. kubectl get pods -n api-demo -w         →  Ready column flipping
  2. kubectl get endpoints api-server        →  count fluctuates 2-3
  3. kubectl describe pod <flapping-pod>     →  "Readiness probe failed:
                                                 context deadline exceeded"
  4. AWS/RDS metrics                         →  DB is healthy, latency
                                                 unchanged, no throttling
  5. kubectl get deploy api-server -o yaml   →  annotations point at the
                                                 merged commit:
                                                   eks-fail-demo/git-sha
                                                   eks-fail-demo/git-ref
                                                   eks-fail-demo/gha-run
  6. Open the PR / commit on GitHub. Diff:
        timeoutSeconds: 1
        failureThreshold: 1
        periodSeconds: 2 (readiness) / 3 (liveness)
  7. Cross-reference with the /health handler in the ConfigMap: it
     opens a psycopg2 connection and does SELECT 1 -- which
     regularly takes 100-800ms and occasionally >1s under normal RDS
     jitter.
  8. Root cause: probe contract is tighter than the actual /health
     SLO can meet.
  9. Fix options:
       a. Revert the timeouts (loosen back to 3-5s, failureThreshold >=2)
       b. Split shallow /healthz (liveness, no DB roundtrip) from
          deep /health (readiness, DB roundtrip, longer timeout)
```

---

## 5. Recovery

`reset-deploy.sh` resets `deploy` back to `main` and force-pushes.
The workflow re-runs, re-applies main's api-app.yaml (with the
original loose probe timings), and the pods stop flapping.

```bash
./scripts/reset-deploy.sh
```

Wait ~60 seconds, then confirm all 3 pods steady Ready:

```bash
kubectl get pods -n api-demo -l app=api-server -o wide
```

Confirm the api-loadgen is back to steady OK output:

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=10
```

Dashboard should recover: **Running pods** back to steady 3, restart
counter stops climbing, everything green.
