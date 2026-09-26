# SponsorRadar-infrastructure

Helm chart and Argo CD desired state for NL Sponsor Radar on a shared K3s host. The operator runbook is `README.md`; the plan lives in the private workbench.

## Rules

- Scope is namespace `sponsor-radar`, AppProject/Application `sponsor-radar`, and tunnel `sponsor-radar`. Never touch shared add-ons, other namespaces, or the `halligalli-k3s` tunnel.
- Any command against the cluster (`kubectl --context k3s-system-admin`), Argo CD, DNS, or Cloudflare (`cloudflared`) needs explicit user approval. Local rendering and validation do not.
- No Secrets in Git. `sponsor-radar-postgres` and `sponsor-radar-tunnel` are created at operation time.
- Images are pinned by digest. The product image is `image.repository` + `image.digest`; a release is a one-line digest bump in `chart/values.yaml`.
- One chart, one `values.yaml`. No Terraform, values profiles, ADRs, or tickets.
- Every container keeps resources, a non-root read-only securityContext, and seccomp `RuntimeDefault`.
- Add a new Kubernetes kind to `argocd/project.yaml` `namespaceResourceWhitelist` in the same change.

## Commands

```sh
set -- --set image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
       --set tunnel.id=00000000-0000-0000-0000-000000000000
helm lint chart "$@"
helm template sponsor-radar chart --namespace sponsor-radar "$@" | kubeconform -strict -summary -
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  argocd/*.yaml
```
