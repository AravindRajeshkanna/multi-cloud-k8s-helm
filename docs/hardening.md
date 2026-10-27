# Hardening: what is locked down, and what is not

Phase 5 put admission rules on the workload namespaces ([policies.md](policies.md)). Phase 6 adds a ceiling, a network posture and a few cluster-level settings. Decisions and the list of what was deliberately not done: [ADR 0009](decisions/0009-hardening-and-operations.md).

## Per workload namespace

`scripts/deploy.sh` creates `web-dev` and `web-prod`, labels them, and applies everything in [policies/namespace/](../policies/namespace/) **before** it installs anything.

| Object | What it does |
|--------|--------------|
| `ResourceQuota` `workload-quota` | At most 30 pods, 4 CPUs and 4 GiB of memory requested, 8 GiB of memory limits, 10 Services, 5 volume claims. Sized for the webapp at its production maximum with room to spare. A quota that tracks CPU and memory also **requires every pod to declare them**. |
| `LimitRange` `workload-limits` | A container's memory limit may be at most 4x its request. Memory only, and no min / max (see below). |
| `NetworkPolicy` `default-deny` | No traffic in or out of any pod unless another policy allows it. |
| `NetworkPolicy` `allow-dns` | Every pod may resolve names through the cluster DNS. |
| `NetworkPolicy` `allow-acme-challenge` | cert-manager's Let's Encrypt challenge pods may receive the validation request. |

On top of those, the `webapp` chart ships its own `NetworkPolicy` that admits only the ingress controller, Prometheus (when scraping is on) and its own `helm test` pod, and lets the test pod reach nothing but the app. Each application is expected to open exactly what it needs the same way.

### Whether the network rules are enforced

A `NetworkPolicy` is a request: if the cluster's network plugin ignores it, it is accepted and does nothing. So:

| Cluster | Enforced by |
|---------|-------------|
| AKS, GKE | Cilium (Azure CNI Overlay + Cilium, Dataplane V2). Already how those clusters are built. |
| EKS | The VPC CNI's network policy support, switched on in Terraform (`enableNetworkPolicy`) in this phase. Without it the policies would have been silently ignored. |
| CI (kind) | Both kind's default plugin and Cilium enforce it, and the CI test asserts that rather than assuming it ([test-network-kind.sh](../scripts/test-network-kind.sh)). Not yet seen on the real clusters. |

Traffic from the node itself (the kubelet's health probes) is not blocked by these policies on any of the three.

### A trap worth knowing: LimitRange defaults

A `LimitRange` with `max` makes Kubernetes use that maximum as the **default limit** for any container that declares none, and `min` becomes the **default request**. That silently fills in what the pod forgot to say, so an admission policy requiring pods to declare their resources passes without the author ever choosing a value. The first version of this LimitRange had `min` and `max`, and the CI test for the resource policy showed pods with no resources at all being admitted with a 2 GiB limit. It now uses only `maxLimitRequestRatio`, which sets no defaults, and the policy test asserts that a pod declaring nothing is refused.

Related: the LimitRange is an earlier admission step than the CEL rules, so in a namespace that has one, a pod with no memory request or limit is refused by the LimitRange's message, not the rule's. The tests keep the two apart.

## Per cluster

| Setting | Where | Why |
|---------|-------|-----|
| EKS network policy enforcement | `infra/aws-eks/main.tf`, vpc-cni `enableNetworkPolicy` | Makes the policies above real on EKS |
| Node metadata locked down | `infra/aws-eks/main.tf`, `metadata_options` | IMDSv2 only and a hop limit of 1, so a pod cannot read the node's cloud credentials. This was already the EKS module's default; it is now stated, so it is a decision rather than luck. |
| Workload identity, not node roles | Phase 1 | Pods get cloud access through Pod Identity / Workload Identity, never through the node |

## What was not done, and why

| Item | Status |
|------|--------|
| AKS Entra ID RBAC with `kubelogin` | Not done. CI today gets the cluster's local admin certificate; switching needs tenant-specific groups and role assignments, and changes how the deploy authenticates. Cannot be tested without a real tenant. |
| Fully private API endpoints | Not done. Needs the CI runner inside each network ([ADR 0001](decisions/0001-platform-decisions.md)). The endpoints stay public but restricted to listed addresses. |
| GKE: stop admitting Google-owned public addresses | Not done. `scripts/cluster-ops.sh allow-ip` rewrites the authorized networks with `gcloud`, and I could not confirm that it preserves such a setting, so changing it risks flapping between Terraform and the script. |
| Restricted egress at the cloud level | Not done. Namespaces deny egress by default, but the NAT gateways are open. A cloud firewall needs an allow-list of what the platform legitimately fetches (registries, cloud APIs), which is only knowable by running. |
| Karpenter instead of the Cluster Autoscaler | Not done. A different autoscaler on EKS needs a real cluster to evaluate. |
| VPA (recommendations) | Not done. It needs hours of real load to say anything. |
| Spot / preemptible nodes | Not done. A cost option for later; node pools stay on-demand. |
| Pod Security `restricted` beyond the workload namespaces | Not done. The platform components (node exporters, ingress, cert-manager) need privileges or have not been audited against it. |
