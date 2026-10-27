# ADR 0005: Chart portability

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

Phase 3's goal is "one chart, multiple values files": the same Helm chart on EKS, AKS and GKE, with the differences kept out of the application logic. The roadmap lists where clouds differ: Service and Ingress annotations, StorageClass, workload identity, node pools.

Phase 1 already made two choices that shrink that list: Traefik is the common ingress controller ([ADR 0002](0002-ingress-controller.md)), and every cluster has the same shape (Standard mode, labelled node pools, workload identity enabled).

## Decisions

1. **Templates contain no cloud logic.** No `if eq .Values.cloud "eks"`, and no cloud names. Differences are values, and a test fails if a template mentions a cloud. A `cloud:` switch inside the chart would make every template a three-way branch that has to be tested three times.

2. **Three layers of values, applied in this order:** `values.yaml` (defaults), `values-<cloud>.yaml`, `values-<env>.yaml`, then `--set` for deployment inputs. A cloud file may set only placement and identity (`nodeSelector`, `tolerations`, `affinity`, `serviceAccount`, `podLabels`) and a marker `env`; environment settings such as replicas, autoscaling and ingress go in the environment files. A test enforces both rules, and that the three clouds render the same objects.

3. **Service and Ingress annotations are not per cloud.** The application Service is `ClusterIP` behind Traefik, so the load-balancer annotations that differ by cloud (NLB, Azure, GKE) belong to Traefik's own Service, which Terraform sets in Phase 1. If an app later needs a cloud load balancer of its own, that is a per-cloud values file entry (`service.type`, `service.annotations`), still without template changes.

4. **Host names are deployment inputs.** Each cloud has a different load-balancer address, so `ingress.host` has no default and the chart refuses to render an enabled ingress without one.

5. **Workload identity is values, not templates.** The chart exposes `serviceAccount.annotations` and `podLabels`, which carry each cloud's mechanism (IRSA annotation, Azure client-id annotation and pod label, GKE service-account annotation). EKS Pod Identity needs nothing in the chart. The example files show each; tests prove they land on the right object.

6. **Strict by default.** A `values.schema.json` rejects unknown keys (typos), a `latest` tag, and missing resource requests or limits. The pod runs under the Kubernetes "restricted" security profile.

7. **Sample workload: podinfo** (Apache-2.0, multi-architecture, health endpoints, runs non-root) behind a chart whose image, command, port and probe paths are values. It is the roadmap's "one simple stateless app" and gives a visible per-cloud marker without any custom image.

8. **Not in this phase:** persistence (the webapp is stateless; StorageClass handling arrives with the first stateful chart), a shared library chart (one app does not show what to share), and publishing charts to an OCI registry (Phase 5). Charts are deployed from this repository's checkout.

## Consequences

- Adding a fourth cloud or environment is a new values file, with no template change.
- Anyone who needs a genuine per-cloud template difference has to argue for it against decision 1; the test makes that visible.
- `additionalProperties: false` means every new value must also be added to the schema. That is the price of catching typos.
- The charts are tested without a cluster (render assertions) and on a throwaway kind cluster in CI. Neither is the same as running on EKS, AKS or GKE; the first real deployment is Phase 4.

## Alternatives considered

- **One chart per cloud.** Triples the maintenance and drifts, which is the thing the roadmap's goal exists to avoid.
- **A `cloud` value that templates branch on.** Works for two or three differences and then becomes unreadable; see decision 1.
- **A common library chart now.** There is one chart, so the library would be a guess.
- **Kustomize overlays.** A reasonable alternative for this shape of difference, but the roadmap and Phase 0 decision are Helm, and Helm values give the same layering plus a schema.
