# Demo runbook

End-to-end script for showing this demo to someone live, structured as
notebook cells you click through top to bottom in
[markdowner](../markdowner/). Each `bash` block has a **▶ Run** button;
clicking it sends the block into the persistent shell at the bottom of
the window.

`text` blocks (no Run button) are reference material — agent prompts,
GitHub UI steps, pasteable explanations.

The demo has three parts:

1. **Baseline** — confirm the cluster is healthy and traffic is flowing
2. **Failure** — pick one of three flavours, trigger it, ask DevOps Agent
3. **Recovery** — restore the cluster

Total time: 15–20 min for a single failure. Add ~5 min per extra
failure if you want to chain a few.

> **markdowner tip:** the shell is persistent. `cd`/`export`/`kill %1`
> from earlier blocks all carry into later ones in this file. Use the
> *Clear* button on the terminal to wipe the screen between sections;
> it doesn't reset the shell state.

---

## 0. Pre-demo checklist

Refresh AWS credentials in the markdowner shell first. The export
commands need to be pasted (different token each time), so set them
once in the terminal pane below before clicking any Run buttons.

```text
export AWS_ACCESS_KEY_ID=…
export AWS_SECRET_ACCESS_KEY=…
export AWS_SESSION_TOKEN=…
```

Verify the credentials are good:

```bash
aws sts get-caller-identity
```

Point kubectl at the cluster:

```bash
aws eks update-kubeconfig --name devops-agent-demo --region us-east-1
```

Quick health check — every pod should be `Running`:

```bash
kubectl get pods -A | grep -vE 'Running|Completed' | grep -v NAME || echo "all pods healthy"
```

Make sure the `deploy` branch is at `main` (no leftover scenario
commit from a previous run):

```bash
./scripts/reset-deploy.sh
```

Start the in-cluster Postgres load generator (pgbench). Without this,
the Postgres pods are idle and FIS experiments like `pod-kill` and
`ebs-pause` produce no visible signal. The API load generator was
started for you automatically by `deploy-rds.sh`.

```bash
./scripts/start-load.sh
```

Confirm pgbench is producing TPS on all three Postgres replicas:

```bash
./scripts/load-status.sh
```

---

## 1. Show the healthy baseline

Run these one at a time to walk through what's deployed.

Three Postgres pods, one per AZ, with their EBS volumes:

```bash
kubectl get pods -l app=postgres -o wide
kubectl get pvc
```

Three API server pods + the load generator hammering them:

```bash
kubectl get pods -n api-demo -o wide
```

Last few entries from the API load generator (proves traffic is
flowing through the API → RDS path):

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=10
```

Smoke-test the API directly. Port-forward in the background, hit the
endpoints, then stop the port-forward.

```bash
kubectl port-forward -n api-demo svc/api-server 18080:80 >/tmp/pf.log 2>&1 &
PF_PID=$!
sleep 2
curl -s http://localhost:18080/health
echo
curl -s http://localhost:18080/write
echo
curl -s http://localhost:18080/query | head -c 400
echo
kill $PF_PID 2>/dev/null
unset PF_PID
echo "[port-forward stopped]"
```

```text
What you'd say while running these:

  "EKS cluster across three AZs. Three Postgres replicas, one per AZ,
   each on its own EBS volume. A REST API talking to RDS Postgres. Two
   load generators — one hitting the API, one running pgbench against
   in-cluster Postgres. Everything green.

   Now we'll break things in three different ways and see how DevOps
   Agent investigates each one."
```

---

## 2. Pick a failure flavour

Three flavours, increasing complexity. **For a 20-minute slot, pick
one — Flavour C is the strongest narrative.** For a longer demo, chain
A → B → C.

### Flavour A — Infrastructure outage (FIS experiment)

Best for "AWS-native infrastructure incident" stories. The cluster
breaks at the AWS layer and the agent has to trace from k8s symptoms
back to an AWS API call.

Trigger:

```bash
./scripts/run-experiment.sh az-disrupt
```

Wait ~30s, then check pod state:

```bash
kubectl get pods -l app=postgres -o wide
kubectl get nodes
```

```text
Hand off to the agent:

  "My EKS cluster `devops-agent-demo` has a Postgres pod that's been
   NotReady for a few minutes. Investigate."

Investigation chain the agent should follow:
  1. kubectl get pods -n default -o wide  →  postgres-0 NotReady
  2. Pod events / node condition          →  node in AZ-a is NotReady
  3. aws ec2 describe-route-tables / NACLs on the AZ-a subnet → blocked
  4. Tag on the disruption                 →  FIS experiment ARN
```

Other FIS options (replace `az-disrupt`):

| Experiment | Symptom | What the agent traces |
|---|---|---|
| `pod-kill` | Random Postgres pod restarts (~30s recovery) | Pod restart count → kubelet logs → no infra signal → FIS API audit |
| `ebs-pause` | Postgres pod stays Running but pgbench errors out, `pg_isready` fails | Pod liveness → CW EBS metrics → volume tag → FIS |
| `attach-hang` | New pods stuck `ContainerCreating` after `kubectl scale sts postgres --replicas=4` | Pod events → CSI controller logs → CloudTrail throttling → IAM deny policy → FIS |

### Flavour B — Operator mistake (manual RDS scripts)

Best for "human ran a wrong command" stories. Doesn't involve git
history; the agent has to read live AWS state.

Break it:

```bash
./scripts/rds-break-sg.sh
```

Wait ~30s, then check the API pods' view of the world:

```bash
kubectl logs -n api-demo -l app=api-server --tail=15
```

```text
Hand off to the agent:

  "API in `api-demo` namespace returning 503s. Find the cause."

Investigation chain:
  1. kubectl logs api-server-...   →  "connection timed out" to RDS endpoint
  2. DNS for the RDS endpoint resolves correctly       →  not a DNS issue
  3. RDS instance is `available`                       →  not an RDS-side outage
  4. RDS security group has no ingress rule on 5432    →  the cause
  5. Recommendation: re-add the rule
```

Recover live, so they see it work:

```bash
./scripts/rds-fix-sg.sh
```

Confirm the API recovered:

```bash
sleep 10
kubectl logs -n api-demo -l app=api-server --tail=10
```

Other manual scenario:

```bash
# ./scripts/rds-kill-connections.sh   # set max_connections=1
# ./scripts/rds-fix-connections.sh    # restore default parameter group
```

### Flavour C — Bad PR caused this (GitHub Actions)

**This is the strongest narrative for an SRE / platform engineering
audience.** The cluster breaks because someone merged a PR. The agent
has to trace from cluster symptoms → recent deployment → git history →
the actual diff that introduced the bug.

The repo has six pre-built broken-by-design branches:

| Branch | Symptom | Difficulty |
|---|---|---|
| `scenario/bad-image-tag` | `ImagePullBackOff` (image doesn't exist) | Trivial |
| `scenario/oom-limits` | `OOMKilled` loop | Easy |
| `scenario/wrong-db-name` | `/health` returns 503 | Easy |
| `scenario/bad-sql` | `/query` returns 500 | Medium |
| `feature/healthz-probe-paths` | Rolling update stuck mid-rollout | Medium — looks like a refactor |
| `feature/tighten-probes` | Pods flap Ready ↔ NotReady, intermittent 5xx | Hard — looks like an incident-driven improvement |

For a demo, **`feature/tighten-probes`** is the most realistic shape of
a real production-breaking PR: a senior engineer's well-meaning
improvement that misses one detail.

```text
Steps in the GitHub UI (not a Run block — do this in the browser):

1. Open https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/compare/deploy...feature/tighten-probes
2. Click "Create pull request"
3. CRUCIAL: change the base branch dropdown from `main` to `deploy`.
   Otherwise the merge pollutes main and the workflow won't fire.
4. Click "Merge pull request" → confirm.
5. Watch the Actions tab — the workflow runs in under a minute.
```

While the workflow is running and immediately after, snapshot the API
state every ~30 seconds. With aggressive probes, pods will start
flipping Ready ↔ NotReady within 2–3 minutes of the rollout.

```bash
kubectl get pods -n api-demo -o wide
kubectl get endpoints api-server -n api-demo
```

Watch the load generator notice the brownout (intermittent ERR lines):

```bash
kubectl logs -n api-demo -l app=api-loadgen --tail=20
```

Inspect the merged Deployment — note the workflow stamps git metadata
on it as annotations:

```bash
kubectl get deploy api-server -n api-demo -o yaml | grep -A3 'annotations:'
```

Pick a flapping pod and look at why it's failing the probe:

```bash
POD=$(kubectl get pods -n api-demo -l app=api-server -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod -n api-demo "$POD" | tail -30
unset POD
```

```text
Hand off to the agent:

  "We just merged a PR and now the API has flaky availability. The
   pods aren't crashing but the loadgen is seeing intermittent
   failures. Investigate."

Investigation chain:
  1. kubectl get pods -n api-demo -w        →  Ready column flipping
  2. kubectl get endpoints api-server -n api-demo  →  count between 2 and 3
  3. kubectl describe pod                   →  "Readiness probe failed:
                                                context deadline exceeded"
  4. kubectl get deploy api-server -o yaml  →  annotations point at the
                                                merged commit:
                                                  eks-fail-demo/git-sha
                                                  eks-fail-demo/git-ref
                                                  eks-fail-demo/gha-run
  5. Pull up the commit on GitHub. Diff: timeoutSeconds: 1,
     failureThreshold: 1, periodSeconds: 2/3.
  6. Cross-reference with server.py (in api-app.yaml): /health does a
     real DB roundtrip. Under normal RDS jitter, occasional /health
     calls take >1s. failureThreshold: 1 means a single slow probe =
     NotReady.
  7. Root cause: probe contract is tighter than the actual /health SLO.
  8. Fix: relax timeout, or split shallow /healthz (liveness) from deep
     /health (readiness).

This is the demo's main act because it shows the agent BRIDGING
CLUSTER STATE TO GIT HISTORY — the actual hard part of being on-call.
```

---

## 3. Recovery

Pick the recovery that matches the failure flavour you ran.

### After Flavour A (FIS experiment)

The experiment auto-stops on its own duration. To stop it sooner:

```bash
RUNNING=$(aws fis list-experiments --region us-east-1 \
  --query "experiments[?state.status=='running'].id" --output text)
for id in $RUNNING; do aws fis stop-experiment --region us-east-1 --id "$id"; done
unset RUNNING
```

### After Flavour B (RDS scripts)

Already done above with `rds-fix-sg.sh`. If you ran the connections
scenario:

```bash
# ./scripts/rds-fix-connections.sh
```

### After Flavour C (Bad PR)

Reset the `deploy` branch back to `main` and force-push. The workflow
re-applies the clean baseline:

```bash
./scripts/reset-deploy.sh
```

Force a rollout so existing pods pick up the rollback (Secret value
changes don't restart pods on their own):

```bash
kubectl rollout restart deployment/api-server -n api-demo
kubectl rollout status deployment/api-server -n api-demo --timeout=120s
```

Confirm recovery:

```bash
kubectl get pods -n api-demo -o wide
kubectl logs -n api-demo -l app=api-loadgen --tail=10
```

---

## 4. Cleanup (after the demo)

Remove the pgbench load generators:

```bash
./scripts/stop-load.sh
```

Safety reset of the deploy branch for next time:

```bash
./scripts/reset-deploy.sh
```

The cluster keeps running at ~$10/day. To shut it down entirely, run
this **outside markdowner** in a regular terminal (it's a 15-minute
operation that you don't want to abort by closing a window):

```text
./scripts/teardown.sh
```

---

## Suggested 20-minute script

```text
0:00  Section 0 + 1 — credentials, baseline, healthy state             3 min
3:00  Flavour A: pod-kill experiment                                   3 min
       - "Self-healing — agent confirms recovery happened"
6:00  Flavour B: rds-break-sg                                          4 min
       - "Operator made a mistake — agent traces it"
       - rds-fix-sg.sh, show recovery
10:00 Flavour C: merge feature/tighten-probes PR                       8 min
       - Walk through the PR diff (looks legit)
       - Merge, watch Actions, watch pods start flapping
       - Hand off to agent: "API is flaky, investigate"
       - Agent traces probes -> commit -> root cause
       - reset-deploy.sh, show recovery
18:00 Wrap-up + Q&A                                                    2 min
```

Escalating narrative: self-heal → human error → committed code defect.
The agent's value increases at each step.
