# ADR 0004: Helm client

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

The roadmap's Phase 2 installs Helm 3 (`get-helm-3`). The open question in the roadmap README was whether to use Helm 3 or Helm 4.

- Helm 4 has been generally available since 12 November 2025.
- Helm 3 is in its end-of-life window ([Helm's announcement](https://helm.sh/blog/helm-v3-end-of-life), 2 June 2026): the last Helm 3 feature release was due 9 September 2026, security fixes end **10 February 2027** (extended from November 2026), and after that there are no updates at all. Kubernetes client-library updates are not backported during the security-only window.
- The clusters run Kubernetes 1.35. Helm only supports the Kubernetes versions near the one it was built against ([version skew policy](https://helm.sh/docs/topics/version_skew/)): a Helm 4 build supports its own Kubernetes minor and the three before it. Helm 4.0.x covers 1.31–1.34, 4.1.x covers 1.32–1.35, 4.3.x covers 1.34–1.37.

## Decision

1. **Use Helm 4.**
2. **Pin an exact version in one place**, [.tool-versions](../../.tool-versions) (asdf/mise format). CI installs it with `azure/setup-helm` (`version-file`); `make prereqs` rejects Helm 3 and tells you when your local Helm is older than the pin. The pin is currently 4.3.1.
3. **Always select the cluster explicitly** with `--kube-context <cluster name>` (`mc-eks`, `mc-aks`, `mc-gke`). Never depend on `current-context`, so a command cannot land on the wrong cloud.
4. **Use the Helm 4 spelling of renamed flags** in scripts and docs here: `--rollback-on-failure` (was `--atomic`) and `--force-replace` (was `--force`). The old names still work in Helm 4 but print a deprecation warning.
5. **Chart repositories** are added only for what this repo installs ([docs/helm.md](../helm.md)). Not added: `ingress-nginx` (retired, [ADR 0002](0002-ingress-controller.md)) and Bitnami (see below).

## Consequences

- When `kubernetes_version` moves (EKS and AKS pin 1.35 in `variables.tf`; GKE follows its release channel), check it against the supported window of the pinned Helm and bump `.tool-versions` first if needed. Bump Helm before the clusters, not after.
- Helm 4 uses server-side apply for new installs; upgrades and rollbacks keep whatever method the release already used. That matters for Phase 4: a chart's resources are applied the Kubernetes way (field ownership, conflicts reported) rather than by Helm's three-way merge.
- Post-renderers are now plugins and `helm registry login` takes a bare hostname. Nothing here uses either yet.
- The Terraform `helm` provider embeds its own Helm library and is not affected by this pin. It manages the platform add-ons (Phase 1); the CLI pinned here deploys workloads (Phase 4).
- `.tool-versions` is not updated by Dependabot. A new Helm patch release has to be bumped by hand.

## Why not Bitnami

Bitnami announced in August 2025 that its free image and chart catalog would stop receiving updates: public images moved to a `bitnamilegacy` repository with no further updates, and the packaged charts' defaults still point at those old images ([for example](https://northflank.com/blog/bitnami-deprecates-free-images-migration-steps-and-alternatives)). That is reported by third parties; confirm the current state against Bitnami's own repository before relying on it. For databases and caches, prefer the project's own chart or operator when Phase 4 needs one.

## Alternatives considered

- **Stay on Helm 3.** Works today, but is on a security-only clock that ends before this repo has any workloads, and gets no Kubernetes client updates.
- **Float on `latest`.** Gives no reproducible CI and can move outside the clusters' supported Kubernetes window without a change in this repo.
