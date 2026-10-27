# Phase 0: Prerequisites & Foundations

## Skills & tools

- Kubernetes fundamentals (pods, deployments, services, namespaces, RBAC, ConfigMaps/Secrets)
- Helm 3 (client only — no Tiller)
- Cloud CLIs: `aws`, `az`, `gcloud` + `kubectl`
- Infrastructure-as-Code: Terraform (recommended) or cloud-native tools (`eksctl`, Azure CLI, `gcloud`)
- Git + basic CI concepts

## Accounts & access

- Cloud accounts with appropriate IAM/permissions
- CI runner with Helm, kubectl, and cloud CLIs installed

## Decide early

- Cluster mode: Standard
- Multi-cluster strategy (one cluster with namespaces)
- Plain Helm + CI

---

## Implementation status

| Item | Where |
|------|-------|
| Decisions recorded | [ADR 0001](../decisions/0001-platform-decisions.md) |
| Local toolchain check | `make prereqs` → [scripts/check-prereqs.sh](../../scripts/check-prereqs.sh) |
| CI runner has the tools | GitHub-hosted `ubuntu-latest` images include the three cloud CLIs, `kubectl` and `helm` (versions vary by image); [setup-terraform](https://github.com/hashicorp/setup-terraform) installs a pinned Terraform. Self-hosted runners must install all of them, and the EKS root needs `aws` on `PATH` for `aws eks get-token`. |
| Cloud accounts & CI credentials | Manual, by the repo owner: [github-secrets.md](../github-secrets.md) |
| Licensing | [LICENSE](../../LICENSE), [NOTICE](../../NOTICE), [licenses.md](../licenses.md) |

### Checklist for the repo owner

- [ ] `make prereqs` passes (install `aws` and `az` if it reports them missing)
- [ ] One account/subscription/project per cloud, with billing enabled
- [ ] State backend created in each cloud ([github-secrets.md](../github-secrets.md))
- [ ] OIDC trust between GitHub and each cloud created
- [ ] GitHub Environments `aws`, `azure`, `gcp` created and populated
