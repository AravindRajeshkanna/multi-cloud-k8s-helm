# ADR 0002: Ingress controller — Traefik, not ingress-nginx

- **Status:** Accepted (revisit in Phase 3)
- **Date:** 2026-10-27

## Context

Phase 1 asks for "an ingress controller (nginx, ALB, Azure Application Gateway, GKE Ingress/Gateway)" on every cluster, and the closing advice is to start with a web service + ingress + cert-manager using the *same chart* on all three clouds.

The Kubernetes project retired **ingress-nginx** in March 2026: no further releases, bug fixes or security patches. See [the Kubernetes retirement notice](https://www.kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) and the [January 2026 steering statement](https://www.kubernetes.io/blog/2026/01/29/ingress-nginx-statement/). Installing it into new clusters would start them on unmaintained, internet-facing software.

## Options

| Option | Same on all clouds | Standard `Ingress` objects | Gateway API | Notes |
|--------|:--:|:--:|:--:|-------|
| ingress-nginx | yes | yes | no | Retired. Rejected. |
| **Traefik** | yes | yes | yes | Maintained; one Helm chart; supports both APIs so charts can migrate gradually. |
| Envoy Gateway | yes | no | yes | Clean Gateway API story, but would force Gateway API into the very first chart. |
| AWS ALB / Azure App Gateway / GKE Ingress | no | yes | partly | Best cloud integration, but three different controllers and annotation sets; defeats "one chart". |

## Decision

Install **Traefik** on every cluster through the shared `core-addons` module. Workload charts reference `ingressClassName: traefik` (exposed as the `ingress_class_name` Terraform output).

Cloud-native ingress is **not ruled out**: Phase 3 can add per-cloud values (ALB, Application Gateway, GKE Gateway) next to the Traefik default, which is what the roadmap's "Cloud-specific handling" section describes.

## Consequences

- One controller to patch and one set of ingress annotations to learn.
- A `LoadBalancer` Service per cluster fronts Traefik. On EKS it is annotated for an NLB; AKS and GKE use their defaults.
- Gateway API CRDs are not installed yet. Enabling Traefik's Gateway API provider is a later, deliberate step.
- Existing guides that say "install ingress-nginx" do not apply here, including the roadmap's Phase 2 suggestion to add an `ingress-nginx` Helm repo.
