# Operations

Day-two: how to keep this running, what to do when it breaks, and how it recovers. The pieces are documented where they live; this is the map.

## The routine

| When | What | Where |
|------|------|-------|
| Wanted | Bring clusters up, deploy | Clusters workflow `up` (+ `deploy=dev`), Deploy workflow ([deploying.md](deploying.md)) |
| After `up` | Check Helm reaches each cluster and the platform is healthy | Helm check workflow ([helm.md](helm.md)) |
| Not wanted | Tear everything down so nothing bills | Clusters workflow `down`; the nightly cost guard catches a forgotten cluster ([cost-control.md](cost-control.md)) |
| Weekly | Read the image scan; bump what has a fix | Supply chain workflow ([supply-chain.md](supply-chain.md)) |
| Before 2026-12-11 | Renew or retire the scan exceptions | [supply-chain-exceptions.txt](../supply-chain-exceptions.txt) |
| Each Kubernetes release | Move the version on, one minor at a time, and keep Helm in its supported window | [infra/README.md](../infra/README.md#changing-versions), [ADR 0004](decisions/0004-helm-client.md) |

## Disaster recovery

There is little to recover, by design. The clusters hold no state worth keeping: they are rebuilt, not repaired.

| What is lost | How it comes back | How long |
|--------------|-------------------|----------|
| A cluster (or all three) | Clusters workflow `up` with `deploy=dev` (or the Deploy workflow). Names stay, addresses change. | About 10 to 20 minutes per cloud, in parallel |
| The applications | The Deploy workflow, from `main` | A few minutes |
| `prod`'s DNS record | Update it to the new load balancer address (printed in the deploy summary) | Manual |
| Metrics, dashboards' data | Not kept | Starts again |

What **is** state, and where it lives: the Terraform state (a versioned bucket or storage account per cloud, kept on purpose by `down`), the cloud identities GitHub uses, and this repository. Losing the state storage orphans a running cluster ([cost-control.md](cost-control.md)), so protect those buckets; there is no backup beyond their versioning.

**No backups of workload data exist**, and `down` deletes volumes. Velero (cluster backup) is deliberately not installed: it needs a bucket and an identity per cloud and has nothing to protect while the only workload is stateless. The first workload with data that matters changes that: use a managed database or object storage outside the cluster ([ADR 0003](decisions/0003-teardown-and-cost-control.md)), or add Velero then. There is no multi-region setup.

## When something is wrong

| Symptom | First look |
|---------|------------|
| A workflow cannot reach the cluster | The runner's address is allowed per run; for `TF_RUNNER` see [helm.md](helm.md#troubleshooting) |
| `up` fails partway | Re-run it; it is idempotent. State lock errors: another run is active or one died ([cost-control.md](cost-control.md#when-something-goes-wrong)) |
| `down` leaves something | It fails on purpose and lists it; delete it and re-run ([cost-control.md](cost-control.md)) |
| A deploy fails | The summary and the printed pods, events and certificate state ([deploying.md](deploying.md#troubleshooting)) |
| Pods are refused | An admission policy: `kubectl describe rs` shows the rule ([policies.md](policies.md)) |
| Pods run but cannot talk | A network policy: the app must open what it needs ([hardening.md](hardening.md)) |
| Nothing arrives at the app | Load balancer, Traefik, Ingress and TLS in that order ([deploying.md](deploying.md#what-each-check-proves)) |
| Weekly scan is red | A fixable vulnerability: bump, or accept it for a while ([supply-chain.md](supply-chain.md)) |
| An alert (with monitoring on) | [observability.md](observability.md) |

## Access

Everything goes through GitHub Actions with short-lived cloud credentials; nobody holds a long-lived cloud key. For your own `kubectl` and `helm`: [helm.md](helm.md#2-contexts-one-per-cluster-named-after-it). The Environments' required reviewers gate runs per cloud, not per environment ([ADR 0006](decisions/0006-deployment-model.md)).
