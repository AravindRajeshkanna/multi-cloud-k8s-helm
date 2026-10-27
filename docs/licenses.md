# Licensing

## This repository

Licensed under the **Apache License 2.0** — see [LICENSE](../LICENSE) (unmodified standard text) and [NOTICE](../NOTICE) (copyright statement). Under section 5 of the license, contributions you submit are licensed the same way unless you state otherwise.

Apache-2.0 was chosen because it is the common license for infrastructure and Kubernetes tooling and includes an explicit patent grant. If you prefer MIT or something else, replace `LICENSE` and `NOTICE` and update this file and the README before accepting outside contributions.

## Third-party software

Nothing from the projects below is copied into this repository. They are referenced by name and version, and downloaded when you run Terraform or Helm. Each keeps its own license.

| Component | Used for | License |
|-----------|----------|---------|
| [Terraform CLI](https://github.com/hashicorp/terraform) 1.6+ | Running the configurations | BUSL-1.1 (source-available) |
| Terraform providers `aws`, `azurerm`, `google`, `helm` | Talking to clouds / Helm | MPL-2.0 |
| [terraform-aws-modules/eks](https://github.com/terraform-aws-modules/terraform-aws-eks), [vpc](https://github.com/terraform-aws-modules/terraform-aws-vpc) | EKS and VPC resources | Apache-2.0 |
| [Helm CLI](https://github.com/helm/helm) 4.x | Deploying workloads (Phase 4), checking the clusters | Apache-2.0 |
| [azure/setup-helm](https://github.com/Azure/setup-helm) (GitHub Action) | Installing the pinned Helm in CI | MIT |
| [podinfo](https://github.com/stefanprodan/podinfo) (container image, default workload of the `webapp` chart) | Sample application | Apache-2.0 |
| [Traefik Helm chart](https://github.com/traefik/traefik-helm-chart) | Ingress controller | Apache-2.0 |
| [metrics-server](https://github.com/kubernetes-sigs/metrics-server) | Resource metrics | Apache-2.0 |
| [cert-manager](https://github.com/cert-manager/cert-manager) | Certificates | Apache-2.0 |
| [Cluster Autoscaler](https://github.com/kubernetes/autoscaler) | EKS node scaling | Apache-2.0 |

Licenses above were read from each project's repository on 2026-10-27; check upstream before relying on them. Container images pulled by the charts carry their own licenses, which this table does not cover.

### Terraform's BUSL license

Terraform 1.6 and later is under the Business Source License 1.1, whose additional use grant permits most production use but not offering a product that competes with HashiCorp's. Read the [license](https://github.com/hashicorp/terraform/blob/main/LICENSE) against your own situation. [OpenTofu](https://opentofu.org/) is an open-source (MPL-2.0) fork that reads Terraform configurations; this repository has not been tested with it.
