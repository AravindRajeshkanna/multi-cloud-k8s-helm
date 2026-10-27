# Supply chain: image scans and SBOMs

The [Supply chain workflow](../.github/workflows/supply-chain.yml) scans every container image the clusters run and records a software bill of materials (SBOM) for each. Why this tooling: [ADR 0008](decisions/0008-policy-and-supply-chain.md).

## What it covers

[scripts/list-images.sh](../scripts/list-images.sh) renders the charts and prints every image they run: the `webapp` workload, and the platform add-ons **at the versions Terraform pins** (Traefik, cert-manager including its challenge solver, metrics-server, the Cluster Autoscaler). Today that is 9 images. When a chart version or an image tag changes, the list changes with it.

It runs weekly (Mondays 04:00 UTC, because new vulnerabilities are published against images that did not change), on demand (*Actions → Supply chain → Run workflow*), and on pull requests that touch the charts or the pinned versions.

## Pass or fail

Each image is scanned with [Grype](https://github.com/anchore/grype). A run **fails** when an image has a vulnerability at or above the threshold that **has a fix available**: then there is a version to bump to. Vulnerabilities without a fix are listed and counted but never fail the run, because there is nothing to do about them yet.

| Setting | Default | Change |
|---------|---------|--------|
| Threshold | `critical` | Repository variable `SCAN_FAIL_SEVERITY` = `high` |

The job summary has a table per image (found / fix available per severity) and the fixable findings that caused a failure, with the version that fixes each. The pass/fail rule is [scripts/scan-summary.sh](../scripts/scan-summary.sh), tested offline.

## SBOMs

Each run uploads one CycloneDX JSON SBOM per image as an artifact (*Actions → the run → Artifacts*, named `sbom-<image>.cdx.json`), kept for the repository's default artifact retention. Use them to answer "does anything we run contain package X?" without re-scanning.

## Responding to a failure

| Image | Fix |
|-------|-----|
| `ghcr.io/stefanprodan/podinfo` | Bump `appVersion` in `charts/webapp/Chart.yaml` (and the chart `version`), or deploy a patched tag now with the Deploy workflow's `image_tag` input |
| A platform add-on (Traefik, cert-manager, metrics-server, autoscaler) | Bump its chart version in Terraform (`infra/modules/core-addons/variables.tf`, `infra/aws-eks/variables.tf`) and run `up`. Keep the autoscaler chart's minor version in step with the Kubernetes version |

## Why Grype and why pinned SHAs

In March 2026 attackers rewrote nearly every version tag of the popular `trivy-action` to run malicious code that stole CI secrets while still printing a normal scan ([Aqua's account](https://www.aquasec.com/blog/trivy-supply-chain-attack-what-you-need-to-know)). A security scanner runs with access to your pipeline, so it is the last thing to trust by a movable tag. This workflow:

- uses Anchore's actions (`scan-action`, `sbom-action`), whose releases are immutable, **pinned to full commit SHAs** (with the version in a comment). Dependabot proposes SHA updates;
- runs in a job with **no secrets and read-only permissions**, so even a compromised action has nothing to steal;
- does not upload SARIF to code scanning, which would need extra write permission.

I found no reported incident for Anchore's tools, which is not proof that there never will be one.

## Limits

- It scans images this repo **runs but does not build** (there is no first-party image yet). Provenance and signing of images become relevant when one is built ([ADR 0007](decisions/0007-delivery-strategy.md)).
- A scan finds known vulnerabilities in packages, not malicious images or misconfiguration.
- `docker.io/traefik` is pulled anonymously from Docker Hub, which rate-limits shared runner addresses; if that scan fails with a rate-limit error, re-run it.
- The first runs happen in the pull request that adds the workflow; whether Grype's results are as expected is judged there.
