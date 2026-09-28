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

## Monitoring

The probe lives in the product repository, not in the cluster: the scheduled GitHub Actions workflow `.github/workflows/probe.yml` in [optiplex331/SponsorRadar](https://github.com/optiplex331/SponsorRadar) runs `scripts/probe.sh https://sponsorradar.halligalli.games` every hour (also `workflow_dispatch`). Each request is tried 3 times, 20 s apart. A failed run is the alert: GitHub emails the owner.

| Check | Fails when |
| --- | --- |
| Page down | `/healthz` does not return 200 through the tunnel |
| Stale data | `/api/status` `last_collect_at` is 30 hours old or more |
| Low collection success | `sources_ok / sources_total` is below 0.95 |
| Postings below floor | `postings` is below 600 |
| Register stale | `register_updated_on` is 45 days old or more |

`/api/status` is cached for 5 minutes in the web pod. `sources_ok` and `sources_total` count each source's latest fetch among runs that started within 6 hours of the newest one, so they describe the last collector run. `postings` counts open Netherlands tech postings.

### Runbooks

Start from the failed run, then open the SSH tunnel and define `k()` as in [First install](#first-install). Every command below that uses `k` or `cloudflared` touches the cluster or Cloudflare: get the owner's approval once for the diagnosis before running any of them. Fixes that change state (rerun, rollback, `UPDATE`) are separate approvals.

```sh
gh run list --repo optiplex331/SponsorRadar --workflow probe.yml --limit 5
gh run view <run-id> --repo optiplex331/SponsorRadar --log-failed
curl -fsS https://sponsorradar.halligalli.games/api/status | jq
```

SQL runs inside the postgres pod over its local socket, so no password is needed:

```sh
psql_radar() { k -n sponsor-radar exec -i postgres-0 -c postgres -- psql -U radar -d radar "$@"; }
psql_radar -c 'SELECT 1'
```

Collector runs are Jobs from the `collector` CronJob (05:00 UTC, `sponsor-radar run`: migrate, seed, register, collect, match, report, prune). The last 3 successful and 3 failed Jobs are kept with their pods, so their logs stay readable:

```sh
k -n sponsor-radar get cronjob collector
k -n sponsor-radar get jobs -l app.kubernetes.io/component=collector --sort-by=.metadata.creationTimestamp
k -n sponsor-radar logs job/<job> --tail=100
```

To rerun collection after a fix, use the `collector-manual` Job in [First install step 6](#6-checks).

#### Page down

`/healthz` does not touch postgres, so this is the web pod, cloudflared, or the tunnel, not the database. A Cloudflare 1033 or 530 page means no tunnel connector is up; a 502 means cloudflared is up but cannot reach web. With one replica each, a node restart also takes the page down until the pods are back.

```sh
curl -sS -o /dev/null -w '%{http_code}\n' https://sponsorradar.halligalli.games/healthz
k -n argocd get application sponsor-radar -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
k -n sponsor-radar get pods -o wide
k -n sponsor-radar describe pod -l app.kubernetes.io/component=web
k -n sponsor-radar logs deploy/web -c migrate --tail=50
k -n sponsor-radar logs deploy/web -c web --tail=50
k -n sponsor-radar logs deploy/cloudflared --tail=50
cloudflared tunnel info sponsor-radar
```

A web pod stuck in `Init` after a release means the `migrate` initContainer failed; see [Rollback](#rollback), keeping in mind that migrations do not roll back.

#### Stale data

`last_collect_at` is the newest successful fetch, so no collector run has collected anything for 30 hours. Likely causes: the CronJob did not start; the Job failed before `collect` (database connection, `migrate`, or `register`: a register error ends the run before any source is fetched); the Job hit `activeDeadlineSeconds` (3600) or its 512Mi memory limit; or every fetch failed.

```sh
k -n sponsor-radar get cronjob collector -o jsonpath='{.spec.suspend} {.status.lastScheduleTime} {.status.lastSuccessfulTime}{"\n"}'
k -n sponsor-radar describe job <job>
k -n sponsor-radar get events --sort-by=.lastTimestamp | tail -20
psql_radar -c "SELECT date_trunc('day', started_at) AS day, count(*) FILTER (WHERE ok) AS ok, count(*) AS runs FROM fetch_runs WHERE started_at > now() - interval '3 days' GROUP BY 1 ORDER BY 1"
```

The Job's log names the failed step. Fix its cause, then rerun collection.

#### Low collection success

Group the failed fetches of the last run by ATS kind and error. `ok IS NOT TRUE` also counts fetches that never finished because the Job was killed mid-run (`ok` and `error` stay NULL).

```sh
psql_radar <<'SQL'
WITH last_run AS (
    SELECT DISTINCT ON (source_id) source_id, ok, error FROM fetch_runs
    WHERE started_at >= (SELECT max(started_at) FROM fetch_runs) - interval '6 hours'
    ORDER BY source_id, started_at DESC, id DESC
)
SELECT s.kind, left(coalesce(r.error, '(unfinished)'), 120) AS error, count(*) AS sources,
       string_agg(s.board, ', ' ORDER BY s.board) AS boards
FROM last_run r JOIN sources s ON s.id = r.source_id
WHERE r.ok IS NOT TRUE
GROUP BY 1, 2 ORDER BY 3 DESC;
SQL
```

Errors are stored as `ExceptionType: message`. Read them this way:

- `HTTPStatusError` with 404 on a few boards: the employer moved or closed its board. Fix `seeds.toml` in the product repository. Removing a seed does not disable its `sources` row, so it keeps failing until `UPDATE sources SET enabled = false WHERE kind = '<kind>' AND board = '<board>'`.
- `HTTPStatusError` with 429 or 503 across one kind: the ATS rate limit, still hit after 3 retries (5, 15, 45 s). The pace is `MIN_INTERVAL` in the product's `ingest.py`.
- Connect or timeout errors across every kind: egress or DNS from the cluster. Rerun collection once the network is back.
- `(unfinished)`: the Job was killed; see [Stale data](#stale-data).

#### Postings below floor

Collection succeeded but open Netherlands tech postings fell under 600 (1,259 on 2026-09-28). A successful fetch closes every posting of that source missing from the payload, so a parse that returns zero on a changed ATS payload closes a whole board. A release that changed parsing or the `is_tech` and `in_netherlands` rules has the same effect on every board. Find boards whose latest successful fetch shrank by more than half:

```sh
psql_radar <<'SQL'
WITH ranked AS (
    SELECT source_id, posting_count,
           row_number() OVER (PARTITION BY source_id ORDER BY started_at DESC, id DESC) AS n
    FROM fetch_runs WHERE ok
)
SELECT s.kind, s.board, prev.posting_count AS before, cur.posting_count AS now
FROM ranked cur
JOIN ranked prev ON prev.source_id = cur.source_id AND prev.n = 2
JOIN sources s ON s.id = cur.source_id
WHERE cur.n = 1 AND cur.posting_count < prev.posting_count / 2
ORDER BY prev.posting_count - cur.posting_count DESC LIMIT 20;
SQL
psql_radar -c "SELECT s.kind, count(*) FILTER (WHERE p.closed_at IS NULL AND p.in_netherlands AND p.is_tech) AS open_tech, count(*) FILTER (WHERE p.closed_at > now() - interval '2 days') AS closed_2d FROM job_postings p JOIN sources s ON s.id = p.source_id GROUP BY 1"
```

Many boards of one kind at zero points to a payload change in that ATS; drops across all kinds right after a release point to the release, see [Rollback](#rollback). Every collect re-parses each payload, so the next run after a fixed release restores the postings.

#### Register stale

`register_updated_on` is the "last updated on" date printed on the IND page in the newest snapshot. Either IND has not published for 45 days, or the `register` step cannot read the page (it moved once, in spring 2026). When the step fails, the whole run stops, so Stale data fails too.

```sh
curl -fsS https://ind.nl/en/public-register-recognised-sponsors/public-register-work | grep -oiE 'last updated on [0-9]{1,2} [a-z]+ [0-9]{4}'
psql_radar -c 'SELECT id, register_updated_on, captured_at FROM register_snapshots ORDER BY captured_at DESC LIMIT 3'
k -n sponsor-radar logs job/<job> | grep -i register
```

If the IND page shows the same date as the snapshot, IND has not updated and there is nothing to fix; the check keeps failing until it does. If the page is newer, or the log shows `TooFewRows` or an HTTP error, fix `register.py` in the product repository, release, and rerun collection.

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
