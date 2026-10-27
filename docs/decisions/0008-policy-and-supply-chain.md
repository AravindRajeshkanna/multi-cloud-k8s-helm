# ADR 0008: Policy and supply-chain controls

- **Status:** Accepted
- **Date:** 2026-10-27

## Context

Phase 5 asks for "policy checks with Kyverno or OPA", image scanning with an SBOM, and validation before commit. The workload namespaces need guard rails (resources, pinned images, trusted sources, HTTPS ingress), and the images the clusters run should be checked for known vulnerabilities. Clusters are disposable and small, and CI is the only deployer ([ADR 0007](0007-delivery-strategy.md)).

## Decisions

1. **Policy is native Kubernetes: ValidatingAdmissionPolicy plus Pod Security Admission.** Rules are CEL expressions in YAML under `policies/admission/`, applied by `scripts/deploy.sh`, and Pod Security Admission's `restricted` profile is switched on by a namespace label. Compared with Kyverno or OPA Gatekeeper:
   - there is **no controller or webhook to install, upgrade or keep healthy** on clusters that are rebuilt often; the API server evaluates the rules in-process;
   - the API is GA since Kubernetes 1.30 and the clusters pin 1.35, so it is available on EKS, AKS and GKE alike;
   - the rules can be tested on a throwaway cluster with plain `kubectl` ([policies.md](../policies.md)), and the same files are what CI and the real clusters enforce.
   What is given up: no **mutation** (setting defaults), no **image signature verification**, no generated resources, and less ergonomic reporting. **Revisit** (Kyverno is the likelier fit) if signed images, defaulting or policy reports become requirements.

2. **Policies opt in by namespace label** (`policy.multi-cloud-k8s-helm.io/enforce=true`), applied to the workload namespaces before anything is installed. Platform namespaces are never labelled, so a policy cannot break Traefik, cert-manager or the autoscaler.

3. **cert-manager's Let's Encrypt challenge pods and Ingresses are exempt, by label.** They are created by the controller, with its own image and no TLS, in the application's namespace; without an exemption the policies would block production certificates. The exemption is a trade: anything carrying that label bypasses the rules. It is acceptable for guard rails against mistakes, and **unproved against a real ACME flow** until there is a domain.

4. **Scanning uses Grype, and SBOMs use Syft (CycloneDX), through Anchore's actions pinned to commit SHAs.** Trivy is the more common choice, but in March 2026 its GitHub Action's tags were rewritten to steal CI secrets. A scanner has access to the pipeline, so it is run in a job with **no secrets and read-only permissions**, from immutable releases pinned by SHA. Those mitigations apply to any scanner; I found no reported incident for Anchore's tools, and that is not a guarantee.

5. **The pass/fail rule is ours, not the action's:** fail only on vulnerabilities at or above a threshold (critical by default) **that have a fix available**. A rule that failed on unfixable findings would be red all the time and ignored. The rule is a tested script, so the job summary is written even when the run fails.

6. **Scans cover everything the clusters run, derived from the charts at the pinned versions**, weekly and on pull requests that change them. The list is generated, so it cannot drift from what is deployed.

7. **A git pre-commit hook** (`make hooks`) runs CI's fast checks locally in about 10 seconds. It is a plain hook with no framework to install; the `pre-commit` framework could wrap the same make targets.

## Consequences

- A change to the chart that breaks a rule fails CI, because every chart install in the throwaway-cluster tests runs in an enforcing namespace.
- A refused pod owned by a Deployment surfaces as `FailedCreate` events, not a Helm error; the deploy script prints those events on failure.
- A new weekly source of red runs: a newly published fixable critical vulnerability. That is the point; the fix is a version bump.
- Pod Security `restricted` is enforced only in the workload namespaces. Extending Pod Security, network policies and RBAC hardening to the rest is Phase 6.

## Alternatives considered

- **Kyverno or OPA Gatekeeper now.** More capable, and a controller per cluster to run and upgrade. Revisit conditions above.
- **Conftest on rendered manifests in CI only.** Catches mistakes at review time but not on the cluster; a rule in the API server covers both, since CI exercises it too.
- **Trivy.** See decision 4.
