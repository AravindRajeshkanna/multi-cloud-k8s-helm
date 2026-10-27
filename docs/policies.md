# Admission policies

Workload namespaces enforce a small set of rules at the Kubernetes API, so a mistake is refused when it is made instead of being found later. They use what Kubernetes ships, with nothing to install: [ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) (CEL rules, GA since Kubernetes 1.30) and the built-in Pod Security Admission. Why not Kyverno or OPA: [ADR 0008](decisions/0008-policy-and-supply-chain.md).

## What is enforced

| Rule | Where | Refuses |
|------|-------|---------|
| `workloads-require-resources` | [policies/admission/require-resources.yaml](../policies/admission/require-resources.yaml) | A container (init containers too) without cpu and memory requests and a memory limit |
| `workloads-pin-image-tags` | [pin-image-tags.yaml](../policies/admission/pin-image-tags.yaml) | An image with no tag, the `latest` tag, and anything that is not a version tag or a digest |
| `workloads-allowed-registries` | [allowed-registries.yaml](../policies/admission/allowed-registries.yaml) | Images outside `ghcr.io/stefanprodan/` (the sample workload's publisher) and ECR, ACR and Artifact Registry |
| `ingress-requires-class-and-tls` | [ingress-tls.yaml](../policies/admission/ingress-tls.yaml) | An Ingress that does not use the `traefik` class or has no `tls` |
| Pod Security Standard `restricted` | namespace label | Privileged pods, root, privilege escalation, added capabilities, host namespaces, and so on |

Pod Security Admission is Kubernetes' own implementation of the restricted standard, switched on with a label rather than reimplemented here. The custom policies cover what that standard does not: resources, versions, sources and ingress.

## Where

Only in namespaces that opt in with two labels, which `scripts/deploy.sh` puts on the workload namespaces (`web-dev`, `web-prod`) **before** it installs anything:

```
policy.multi-cloud-k8s-helm.io/enforce=true
pod-security.kubernetes.io/enforce=restricted
```

Platform namespaces (`ingress`, `cert-manager`, `kube-system`) are not labelled, so the policies cannot affect Traefik, cert-manager or the autoscaler. The rules are checked when a pod or ingress is created or updated; pods that already exist are not touched when a policy is added.

The `webapp` chart is built to pass all of them, and a test proves it for every cloud and environment (below).

### cert-manager's challenge objects

When Let's Encrypt validates a domain (HTTP-01), cert-manager creates its own pod and Ingress in the namespace of the certificate. Those are plain HTTP and use cert-manager's image, so the four policies skip objects carrying the label `acme.cert-manager.io/http01-solver`. This exemption exists so that production certificates can be issued in an enforcing namespace. **Not yet proved against a real ACME flow** (that needs a domain); the test proves the exemption is by label only, and that the same pod without the label is refused.

## Try it

```sh
kubectl --context mc-eks -n web-dev run bad --image=nginx:latest
```

The request is refused, and the message names the rule that refused it (`workloads-pin-image-tags`, and the registry and resources rules too, since this pod breaks all three).

A refused pod owned by a Deployment shows up as `FailedCreate` events on its ReplicaSet (`kubectl -n web-dev describe rs`), not as an error from Helm, which then times out waiting. The deploy script prints those events when it fails.

## Change the rules

- **Allow another registry:** add a prefix in `allowed-registries.yaml` (one place), then re-run the Deploy workflow, which applies everything in `policies/admission/`.
- **Add a rule:** a new file in `policies/admission/` with a policy and a binding that selects the same label, and a case in [scripts/test-policies-kind.sh](../scripts/test-policies-kind.sh) that is refused and one that passes.
- **Switch a rule to warn first:** change the binding's `validationActions` from `["Deny"]` to `["Warn"]`; kubectl then prints the message without refusing.

## How it is tested

[scripts/test-policies-kind.sh](../scripts/test-policies-kind.sh) runs in CI on a fresh kind cluster, with server-side dry runs: the real API server evaluates the real policies and nothing is scheduled. It checks that each violation is refused with the right rule, that compliant objects pass, that an unlabelled namespace is unaffected, that the challenge exemption is label-scoped, and that **every application pod, test pod and production ingress the chart renders** (3 clouds x 2 environments) is admitted. The chart installs in [test-charts-kind.sh](../scripts/test-charts-kind.sh) also run in enforcing namespaces, so a chart change that breaks a rule fails CI.

## Limits

- Validating rules only: no mutation (adding defaults) and no image signature checks. Those are reasons to consider Kyverno later ([ADR 0008](decisions/0008-policy-and-supply-chain.md)).
- They are guard rails against mistakes, not a security boundary against someone who can edit the policies or the namespace labels.
- Not yet run on EKS, AKS or GKE. The API is GA since 1.30 and the clusters pin 1.35, but the first deployment is the first real test.
