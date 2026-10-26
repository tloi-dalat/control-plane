# Operations

## Deploy

| Task | How |
|---|---|
| Deploy to development | Merge to `main` in the app repo. CI builds `main-<sha>` and a bot commits the tag here |
| Release | In the app repo, merge `main` → `release`: tags the next minor (`0.1.3` → `0.2.0`) and builds it |
| Hotfix | `git switch -c releases/<name> <tag>`, commit, push: tags the next patch. Merge the fix back to `main` |
| Deploy to production | PR setting `image.tag` in `clusters/production/online-judge/<app>/values.yaml`. Copy the block from the release's notes. `site` and `event` move together |
| Roll back | Revert the tag change (dev: the bot commit; production: a PR back to the previous tag) |

Release tags are immutable: CI never rebuilds an existing `X.Y.Z`. Each repo's **Deployments** tab shows what
runs in each environment; its **Releases** tab has the images and the values to paste.

## Configure

| Task | How |
|---|---|
| Change a setting | `env:` in the app's `values.yaml`. Never secrets (the lint workflow rejects them) |
| Change a secret | Edit it in Infisical. The Secret updates within a minute and the pods restart |
| Add a secret | Add it to `/online-judge/site`: `site/` loads every key there. Other apps need a `secretKeyRef` |
| Add a hostname | PR to `terraform-cloudflare` (`zero-trust/tunnel/tunnels/control-plane-<env>.yaml`) |
| Add a service | Add `clusters/<env>/<namespace>/<app>/`; the ApplicationSet creates the app `<namespace>-<app>`. Names: see [Naming](#naming) |
| Change chart options | Every app uses `oci://ghcr.io/tloi-dalat/charts/app`, pinned in its `kustomization.yaml` |
| Change k3s settings | `bootstrap/<env>/k3s-config.yaml` → `/etc/rancher/k3s/config.yaml`, restart k3s. Never `disable-network-policy`: it confines the judges |

## Scale

- Site: autoscales in production (`autoscaling` in `site/site.yaml`). Raise `minReplicas` before a big contest.
- Judges: change `replicaCount` in `judge/values.yaml` and register or remove `judge-<n>` in the site admin.
  Keep it within the cores the VPS can spare, or time limits get unfair.
- Bridge, event and redis stay at one replica.
- Judges: `DMOJ_JUDGE_INDEX` must sort before `DMOJ_JUDGE_NAME` in `env` (the chart sorts env by name).

## Look around

```bash
kubectl -n argocd get applications
kubectl -n online-judge get pods
kubectl -n online-judge logs deploy/site --tail=50
kubectl -n online-judge logs job/site-migrate
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite   # sync now
```

## Backups

Production only, to R2 bucket `tloi-backups` under `production/`, every day at 03:00 (Asia/Ho_Chi_Minh). A failed or
missing backup raises an alert in Discord (§ Monitoring); the rules sit next to each part (`alerts.yaml`).

| Part | How | Folder | Kept |
|---|---|---|---|
| MariaDB, PostgreSQL | k8up `Schedule` in `database/backup/schedule.yaml` runs `mariadb-dump` in one MariaDB pod and `pg_dumpall` in one Postgres pod (the `k8up.io/backupcommand` annotations in `mariadb.yaml` and `postgres.yaml`; k8up picks one pod per database, primary or replica), and stores each output with restic as `/database-mariadb.sql` and `/database-postgres.sql`. The selectors match pods only, so the data volumes are never copied raw | `database/` | 7 daily, 4 weekly, 6 monthly |
| Files | k8up (`backup/operator/`) `Schedule` in `backup/data`: one restic snapshot of all of `/home/tloi/data` (a read-only volume `backup-data`), except `database/` (covered above) and `monitoring/`; prune 04:00, check Sundays | `data/` | 7 daily, 4 weekly, 6 monthly |

| Task | How |
|---|---|
| Run a backup now | A k8up `Backup` in `database` (both databases) or `backup` (files) |
| Restore MariaDB | `restic -r s3:https://<account>.r2.cloudflarestorage.com/tloi-backups/production/database dump latest <file>.sql \| mariadb -uroot -p` in the primary (find the file with `restic ls latest`) |
| Restore PostgreSQL | `restic -r s3:https://<account>.r2.cloudflarestorage.com/tloi-backups/production/database dump latest <file>.sql \| psql` as `postgres` in the primary; the dump drops and recreates each database |
| Restore files | A k8up `Restore` in `backup`, or `restic -r s3:https://<account>.r2.cloudflarestorage.com/tloi-backups/production/data restore latest --target <dir>`; files are under `data/` in the snapshot |
| Back up a new app | Nothing, as long as its data is under `/home/tloi/data`. Skip a folder with another `--exclude` in the `k8up.io/backup-restic-args` annotation of `backup/data/storage.yaml` |

restic needs `RESTIC_PASSWORD`, and the R2 keys as `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (Infisical `/backup`).

## Monitoring

Production: kube-prometheus-stack in `monitoring/prometheus` (Prometheus, Alertmanager, kube-state-metrics,
node-exporter; no Grafana yet). Prometheus keeps 15 days on `/home/tloi/data/monitoring/prometheus`.

- Alertmanager posts `warning` and `critical` alerts to Discord, repeats them every 12h until resolved, and posts
  `Watchdog` once a day: no Watchdog message means alerting itself is broken.
- It scrapes every `ServiceMonitor`/`PodMonitor` and loads every `PrometheusRule` in the cluster. Add an alert by
  putting an `alerts.yaml` next to the app.
- Each alert posts once when it starts and once when it resolves, with both times (routes and receivers in
  `alertmanager.yaml`, message format in `alert.tmpl`), after the text in Infisical `DISCORD_ALERT_PREFIX`. The chart's built-in rules cover crash loops, pods not ready, replicas missing, the site's HPA at
  max replicas, failed jobs, full volumes and node pressure. `monitoring/prometheus/alerts.yaml` adds the
  capacity alerts, which say what to scale:

  | Alert | Means | Scale |
  |---|---|---|
  | `ContainerMemoryNearLimit` (90%), `ContainerOOMKilled` | an app outgrows its memory limit | its `limits.memory` |
  | `ContainerCPUNearLimit` (90%) | an app is throttled | its `limits.cpu`, or replicas |
  | `KubeHpaMaxedOut` | the site autoscaler is at `maxReplicas` | `maxReplicas`, if the node has room |
  | `NodeCPUHigh`, `NodeMemoryHigh` (85%), `NodeRequestsHigh` (90% reserved) | the VPS itself is full | lower limits, or a bigger VPS |
  | `NodeDiskHigh` (80%) | the disk holding `/home/tloi/data` | clean up, or grow the disk |
  | `MariaDBConnectionsHigh`, `PostgresConnectionsHigh` (80%) | close to `max_connections` | `max_connections` in `mariadb.yaml`/`postgres.yaml` |
  | `MariaDBReplicationLag`, `PostgresReplicationLag` (5m) | the replica can't keep up | database CPU/memory |

  Plus ArgoCD apps unhealthy or out of sync, the Cloudflare tunnel down, databases down or replication stopped
  (`database/mariadb/alerts.yaml`, `database/postgres/alerts.yaml`), and backups.
- k3s runs etcd, the scheduler, the controller manager and kube-proxy inside its own process, so their monitors and
  alerts are off.
- Look at it: `kubectl -n monitoring port-forward svc/monitoring-prometheus 9090` (alerts at
  http://localhost:9090/alerts) and `svc/monitoring-alertmanager 9093` (silences).

## Database

mariadb-operator in `clusters/<env>/database/` (`mariadb-operator/`, `mariadb/`). Apps write to
`mariadb-primary.database.svc.cluster.local`; SQL Lab reads `mariadb-secondary` (the replica).

| Task | How |
|---|---|
| Root shell | `kubectl -n database exec -it mariadb-0 -c mariadb -- mariadb -uroot -p` |
| Replication status | `kubectl -n database get mariadb mariadb -o jsonpath='{.status.replication}'` |
| Add an app database | Copy `mariadb/online-judge.yaml` (Database, User, Grant), add its password key to `/database/mariadb` |
| Remove one | Delete its file. Databases and users have `cleanupPolicy: Skip`: drop them by hand if you mean it |
| Change server settings | `myCnf` in `mariadb.yaml`; the operator restarts the replica, then the primary |
| Upgrade MariaDB | `image` in `mariadb.yaml`, same order |
| Upgrade the operator | Both chart versions in `mariadb-operator/`, after reading its release notes. Its CRDs are never pruned |
| Switch primary | `replication.primary.podIndex` in `mariadb.yaml` |
| Restore | From the nightly dump (§ Backups) |
| Change the secret or volume names | The operator refuses a new `rootPasswordSecretKeyRef`: delete the `MariaDB`, its PVCs and old PVs, then sync. Data stays on disk |
| PostgreSQL (production) | CloudNativePG: `database/postgres-operator/` and the `Cluster` in `database/postgres/`. Apps write to `postgres-primary.database`; SQL Lab reads `postgres-secondary` (CloudNativePG's own `postgres-rw` also stays). A database is a role under `managed.roles` in `postgres.yaml`, its password target in `secret.yaml` and a `Database` like `newsletter.yaml`. Instances are `postgres-1`, `postgres-2`, each on its own PV. Keep the empty `app` database (`app.yaml`): CloudNativePG runs its metrics queries there |

## SQL Lab

`sqllab.tloi.shop` / `sqllab.tloi.vn`: DbGate on the MariaDB replica (production also the PostgreSQL replica) as read-only user `sqllab`, behind Cloudflare Access
. `argocd.tloi.shop` / `argocd.tloi.vn`: ArgoCD, read-only.

| Task | How |
|---|---|
| Allow an email or team | terraform-cloudflare, `control-plane-<env>.yaml` → `access.<hostname>` |
| Show another database | A `Grant` like `sqllab-online-judge` in `database/mariadb/sqllab.yaml` |

## Data

- Media and problem data: `/home/tloi/data/online-judge`. Database: `/home/tloi/data/database`. Production backs
  them up to R2 (§ Backups).
- Volumes are local PVs ArgoCD never deletes. A PV's path can't change; moving data means a new PV and PVC. Review
  any PR that touches `storage/`.
- No secrets in git: values live in Infisical, this repo only maps folders to Secrets.

## Naming

Inside a namespace, names don't repeat it. Cluster-wide objects (PVs) do.

| Thing | Pattern | Example |
|---|---|---|
| App directory, Helm release, Service | `<app>` | `online-judge/site` → `site.online-judge.svc.cluster.local` |
| Image | `ghcr.io/tloi-dalat/<namespace>-<app>` | `online-judge-site` |
| Secret, Infisical folder | `<app>-env`, `/<namespace>/<app>` | `site-env`, `/online-judge/site` |
| ConfigMap | `<app>-<purpose>` | `media-nginx` |
| PVC | `<app>` or the data it holds | `media`, `sqllab` |
| PV | `<namespace>-<app>` | `online-judge-media` |
| Data directory | `/home/tloi/data/<namespace>/<app>` | `/home/tloi/data/platform/sqllab` |
