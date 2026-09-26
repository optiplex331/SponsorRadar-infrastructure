# SponsorRadar-infrastructure

Desired state for [NL Sponsor Radar](https://github.com/optiplex331/SponsorRadar) on a shared K3s host, delivered by Argo CD and exposed at `https://sponsorradar.halligalli.games` through a dedicated Cloudflare Tunnel.

| Path | Holds |
| --- | --- |
| `chart/` | One Helm chart: web Deployment (migrations in an initContainer), collector CronJob, postgres StatefulSet, cloudflared, NetworkPolicies. |
| `chart/values.yaml` | The only values file. The product image digest and the tunnel ID live here. |
| `argocd/` | AppProject and auto-sync Application `sponsor-radar`. Applied once by hand. |

Secrets are not in this repository. They are created in the cluster at operation time.

## Boundaries

The K3s host runs other workloads. Touch only:

- namespace `sponsor-radar`;
- AppProject and Application `sponsor-radar` in namespace `argocd`;
- Cloudflare Tunnel `sponsor-radar` and the DNS record `sponsorradar.halligalli.games`.

Never change shared add-ons (Argo CD itself, Traefik, local-path, CoreDNS), other namespaces, or the `halligalli-k3s` tunnel.

Network: ingress is default-deny in the namespace; postgres accepts only web and collector pods on 5432; web accepts only cloudflared on 8000; cloudflared accepts nothing. Egress is open on purpose: the collector calls public ATS APIs and the IND register, and cloudflared dials out to Cloudflare.

## First install

All commands run from the repository root on the operator machine. The kube context `k3s-system-admin` points at `https://127.0.0.1:16443`, so open the SSH tunnel to the K3s API first and keep it running:

```sh
ssh -N -L 16443:127.0.0.1:6443 <k3s-host>
```

```sh
k() { kubectl --context k3s-system-admin "$@"; }
```

### 1. Read-only preflight

Stop if any check fails.

```sh
# Node architecture (expect amd64) and allocatable ephemeral storage.
k get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\t"}{.status.allocatable.ephemeral-storage}{"\n"}{end}'

# Actual free disk on the node filesystem (kubelet stats, no pod). Expect well over 5Gi free.
for n in $(k get nodes -o jsonpath='{.items[*].metadata.name}'); do
  k get --raw "/api/v1/nodes/$n/proxy/stats/summary" | jq --arg n "$n" '{node: $n, availableGiB: (.node.fs.availableBytes / 1073741824 | floor), capacityGiB: (.node.fs.capacityBytes / 1073741824 | floor)}'
done

# Argo CD CRDs and the local-path StorageClass exist.
k get crd applications.argoproj.io appprojects.argoproj.io
k get storageclass local-path

# Nothing named sponsor-radar exists yet. Each command must report NotFound.
k get namespace sponsor-radar
k -n argocd get appproject sponsor-radar
k -n argocd get application sponsor-radar
```

### 2. Namespace

```sh
k create namespace sponsor-radar
```

### 3. Postgres password

Generated on the fly and never printed. Postgres reads it only when it initializes an empty volume; changing the Secret later does not change the database password.

```sh
openssl rand -hex 24 | tr -d '\n' \
  | k -n sponsor-radar create secret generic sponsor-radar-postgres --from-file=password=/dev/stdin
```

### 4. Cloudflare Tunnel

```sh
cloudflared tunnel create sponsor-radar
TUNNEL_ID=$(cloudflared tunnel list -o json | jq -r '.[] | select(.name == "sponsor-radar") | .id')

k -n sponsor-radar create secret generic sponsor-radar-tunnel \
  --from-file=credentials.json="$HOME/.cloudflared/$TUNNEL_ID.json"

cloudflared tunnel route dns sponsor-radar sponsorradar.halligalli.games
```

Set `tunnel.id` in `chart/values.yaml` to `$TUNNEL_ID`. Also set `image.digest` (see [Release](#release)); the chart refuses to render without both. Commit and push to `main`.

### 5. Argo CD

The repository must be public on GitHub and `main` must contain step 4's values.

```sh
k apply -f argocd/project.yaml
k apply -f argocd/application.yaml
```

### 6. Checks

```sh
# Expect "Synced Healthy".
k -n argocd get application sponsor-radar -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'

# Running image digest must equal image.digest in chart/values.yaml.
k -n sponsor-radar get pods -l app.kubernetes.io/component=web \
  -o jsonpath='{range .items[*].status.containerStatuses[*]}{.imageID}{"\n"}{end}'
grep 'digest:' chart/values.yaml

curl -fsS https://sponsorradar.halligalli.games/healthz
curl -fsS https://sponsorradar.halligalli.games/api/status

# One collector run now instead of waiting for 05:00 UTC.
k -n sponsor-radar create job --from=cronjob/collector collector-manual
k -n sponsor-radar wait --for=condition=complete job/collector-manual --timeout=3600s
k -n sponsor-radar logs job/collector-manual --tail=50
k -n sponsor-radar delete job collector-manual
```

## Release

Product CI pushes `ghcr.io/optiplex331/sponsor-radar:main`. A release is a one-line commit that changes `image.digest` in `chart/values.yaml`. Get the digest with either:

```sh
docker buildx imagetools inspect ghcr.io/optiplex331/sponsor-radar:main --format '{{ .Manifest.Digest }}'

gh api /users/optiplex331/packages/container/sponsor-radar/versions \
  --jq '.[] | select(.metadata.container.tags | index("main")) | .name'
```

Argo CD syncs automatically. The web initContainer runs `sponsor-radar migrate` before the new web container starts.

## Rollback

`git revert` the digest commit and push. Data stays on the PVC. Migrations are not reverted, so the older image must tolerate the newer schema.

## Removal

The Application has no resources finalizer, so deleting it leaves the workload running; delete the namespace explicitly. Deleting the namespace deletes the PVC and, with `local-path`, the data.

```sh
k -n argocd delete application sponsor-radar
k -n argocd delete appproject sponsor-radar
k delete namespace sponsor-radar

cloudflared tunnel cleanup sponsor-radar
cloudflared tunnel delete sponsor-radar
rm "$HOME/.cloudflared/$TUNNEL_ID.json"
```

Then delete the `sponsorradar.halligalli.games` CNAME in the Cloudflare dashboard; `cloudflared` does not remove DNS records.

## Local validation

```sh
set -- --set image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000 \
       --set tunnel.id=00000000-0000-0000-0000-000000000000
helm lint chart "$@"
helm template sponsor-radar chart --namespace sponsor-radar "$@" | kubeconform -strict -summary -
```
