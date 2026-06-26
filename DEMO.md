# Demo runbook

End-to-end script for showing this demo to someone live. Assumes the
cluster is already deployed (see [`README.md`](README.md) for the
one-time setup).

The demo has three parts:

1. **Baseline** — show the cluster is healthy and traffic is flowing
2. **Failure** — pick one of three flavours, trigger it, ask DevOps Agent
3. **Recovery** — restore the cluster

Total time: 15-20 min for a single failure. Add ~5 min per extra
failure if you want to chain a few.

---

## 0. Pre-demo checklist (do beforehand)

Run **at least 5 minutes before** the demo so everything has settled:

```bash
# Refresh AWS credentials in this shell.
# (Verify with `aws sts get-caller-identity`.)

# Make sure your kubeconfig points at the demo cluster.
aws eks update-kubeconfig --name devops-agent-demo --region us-east-1

# Quick health check — every pod should be Running.
kubectl get pods -A | grep -vE 'Running|Completed' | grep -v NAME

# Make sure the deploy branch is at main (no leftover scenario commit).
./scripts/reset-deploy.sh

# Start the in-cluster Postgres load generator (pgbench).
# Without this, Postgres pods are idle — pod-kill / ebs-pause won't
# show any visible impact. The API load generator is started for you
# automatically by deploy-rds.sh.
./scripts/start-load.sh
./scripts/load-status.sh    # verify TPS > 0 on all three targets
```

Have these tabs/windows open before you start talking:

| Window | Command |
|---|---|
| **A** Cluster overview | `watch -n 2 kubectl get pods -A` |
| **B** API load generator logs | `kubectl logs -n api-demo -l app=api-loadgen -f --tail=20` |
| **C** Postgres load TPS | `watch -n 5 ./scripts/load-status.sh` |
| **D** Free terminal | (for `kubectl describe`, `curl`, FIS commands) |
| **E** GitHub Actions tab | <https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/actions> |
| **F** GitHub branches view | <https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/branches> |

---

## 1. Baseline (~2 min)

Walk through what you're showing. Sample script:

> *"This is an EKS cluster spread across three AZs. Three Postgres
> replicas, one per AZ, each on its own EBS volume. A REST API talking
> to RDS Postgres. Two load generators — one hitting the API, one
> running pgbench against the in-cluster Postgres. Everything green.*
>
> *Now we'll break things in three different ways and see how DevOps
> Agent investigates each one."*

Quick smoke test from a free terminal:

```bash
kubectl port-forward -n api-demo svc/api-server 8080:80 &
PF=$!
curl -s http://localhost:8080/health      # {"status": "ok", "db": "connected"}
curl -s http://localhost:8080/query       # last 10 events
curl -s http://localhost:8080/write       # inserts a new event
kill $PF
```

---

## 2. Pick a failure flavour

Three flavours, in order of complexity. **For a 20-minute slot, pick
one — Flavour C is the strongest narrative.** For a longer demo, chain
A → B → C.

### Flavour A — Infrastructure outage (FIS experiment)

Best for "AWS-native infrastructure incident" stories. The cluster
breaks at the AWS layer and the agent has to trace from k8s symptoms
back to an AWS API call.

```bash
./scripts/run-experiment.sh az-disrupt
```

Within ~30s: the Postgres pod in AZ-a goes `NotReady`. It can't
reschedule because its EBS PV is pinned to AZ-a.

Ask DevOps Agent:

> *"My EKS cluster `devops-agent-demo` has a Postgres pod that's been
> NotReady for a few minutes. Investigate."*

Investigation chain the agent should follow:
1. `kubectl get pods -n default -o wide` → `postgres-0` NotReady
2. Pod events / node condition → node in AZ-a is `NotReady`
3. `aws ec2 describe-route-tables` / NACLs on the AZ-a subnet → blocked
4. Tag on the disruption → FIS experiment ARN

**Other FIS options:**

| Experiment | Symptom | What the agent traces |
|---|---|---|
| `pod-kill` | Random Postgres pod restarts (~30s recovery) | Pod restart count → kubelet logs → no infra signal → FIS API audit |
| `ebs-pause` | Postgres pod stays Running but pgbench errors out, `pg_isready` fails | Pod liveness → CW EBS metrics → volume tag → FIS |
| `attach-hang` | New pods stuck `ContainerCreating` after `kubectl scale sts postgres --replicas=4` | Pod events → CSI controller logs → CloudTrail throttling → IAM deny policy → FIS |

### Flavour B — Operator mistake (manual RDS scripts)

Best for "human ran a wrong command" stories. Doesn't involve git
history; the agent has to read live AWS state.

```bash
./scripts/rds-break-sg.sh        # remove RDS security group ingress on port 5432
# wait ~30s — API pods now return 503 from /health
```

Window B (the API loadgen logs) starts going red. Ask the agent:

> *"API in `api-demo` namespace returning 503s. Find the cause."*

Chain:
1. `kubectl logs api-server-...` → `connection timed out` to RDS endpoint
2. DNS for the RDS endpoint resolves correctly → not a DNS issue
3. RDS instance is `available` → not an RDS-side outage
4. RDS security group has no ingress rule for port 5432 from VPC CIDR
5. Recommendation: re-add the rule

Recover live so they see it work:

```bash
./scripts/rds-fix-sg.sh
```

Within seconds, window B turns green again.

**Other manual scenario:**
- `./scripts/rds-kill-connections.sh` sets `max_connections=1` and reboots → API pods intermittently fail with "too many connections". Recover with `./scripts/rds-fix-connections.sh`.

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

For a demo, pick **`feature/tighten-probes`**: it's the most realistic
shape of a real production-breaking PR — a senior engineer's well-
meaning improvement that misses one detail.

#### Steps

1. Open the PR comparison in window F:
   <https://github.com/stefansaftic/aws-devops-agent-eks-rds-demo/compare/deploy...feature/tighten-probes>
2. Click **Create pull request**.
3. **Crucial:** the base branch dropdown defaults to `main`. **Change
   it to `deploy`.** Otherwise the merge pollutes main and the
   workflow won't fire.
4. Click **Merge pull request** → confirm.
5. Switch to window E (Actions tab). The `deploy-scenario` workflow
   starts within ~10 seconds and runs for under a minute.
6. Watch window A. New api-server pods come up, then start flapping
   `1/1 Ready ↔ 0/1` every minute or two. Window B (loadgen) shows
   periodic 503s. The cluster is in a "brownout" state — not down,
   just unreliable.

Wait until you see at least one Ready→NotReady flap (~2-3 min after
merge), then ask the agent:

> *"We just merged a PR and now the API has flaky availability. The
> pods aren't crashing but the loadgen is seeing intermittent failures.
> Investigate."*

Investigation chain:
1. `kubectl get pods -n api-demo -w` → Ready column flipping
2. `kubectl get endpoints api-server -n api-demo` → endpoint count
   fluctuating between 2 and 3
3. `kubectl describe pod` on a flapping pod → `Readiness probe failed:
   context deadline exceeded`
4. **Cluster → git bridge:** `kubectl get deploy api-server -n
   api-demo -o yaml` shows annotations the workflow stamps on:
   - `eks-fail-demo/git-sha` — the merged commit
   - `eks-fail-demo/git-ref` — `feature/tighten-probes`
   - `eks-fail-demo/gha-run` — the GitHub Actions run id
5. Pull up the commit on GitHub. The diff: `timeoutSeconds: 1`,
   `failureThreshold: 1`, `periodSeconds: 2`/`3`.
6. Cross-reference with `server.py` (also in api-app.yaml): `/health`
   does a real DB roundtrip. Under normal RDS jitter, occasional
   `/health` calls take >1s. `failureThreshold: 1` means a single
   slow probe = NotReady.
7. **Root cause:** the probe contract is tighter than the actual
   `/health` SLO supports.
8. Recommended fix: relax the timeout, or split health checks
   (shallow `/healthz` for liveness, deep `/health` for readiness).

This is the demo's main act because it shows the agent **bridging
cluster state to git history** — the actual hard part of being on-call.

---

## 3. Recovery (~30 seconds)

Match the recovery to the failure flavour:

| Flavour | Recovery |
|---|---|
| A — FIS | Wait for experiment timeout, or `aws fis stop-experiment --id <id> --region us-east-1` |
| B — RDS scripts | `./scripts/rds-fix-sg.sh` (or `rds-fix-connections.sh`) |
| C — Bad PR | `./scripts/reset-deploy.sh` — resets `deploy` branch to `main` and force-pushes; the workflow re-applies the clean baseline |

In all cases, watch windows A and B return to steady state. For
Flavour C, the `reset-deploy.sh` script triggers a real workflow run,
so you can also point at the Actions tab to show the recovery is
itself a CI deploy.

---

## 4. Cleanup (after the demo)

```bash
./scripts/stop-load.sh           # remove the pgbench load generators
./scripts/reset-deploy.sh        # safety: leave deploy = main for next time
```

Cluster keeps running at ~$10/day. To shut it down entirely:

```bash
./scripts/teardown.sh
```

---

## Suggested 20-minute script

```
0:00  Baseline (windows A-F open, narrate the architecture)         2 min
2:00  pod-kill experiment                                            3 min
       - "Self-healing — agent confirms recovery happened"
5:00  rds-break-sg                                                   4 min
       - "Operator made a mistake — agent traces it"
       - rds-fix-sg.sh, show recovery
9:00  Merge feature/tighten-probes PR                                8 min
       - Walk through the PR diff (looks legit)
       - Merge, watch Actions, watch pods start flapping
       - Hand off to agent: "API is flaky, investigate"
       - Agent traces probes -> commit -> root cause
       - reset-deploy.sh, show recovery
17:00 Wrap-up + Q&A                                                  3 min
```

Escalating narrative: self-heal → human error → committed code defect.
The agent's value increases at each step.
