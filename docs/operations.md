# Operations

## Deploy

| Task | How |
|---|---|
| Deploy to development | Merge to `main` in the app repo. CI builds `main-<sha>` and a bot commits the tag here |
| Release | In the app repo, merge `main` → `release`: tags the next minor (`0.1.3` → `0.2.0`) and builds it |
| Hotfix | `git switch -c releases/<name> <tag>`, commit, push: tags the next patch. Merge the fix back to `main` |
| Deploy to production | PR setting `image.tag` in `clusters/production/online-judge/<app>/values.yaml`. Copy the block from the release's notes. `core` and `wsevent` move together |
| Roll back | Revert the tag change (dev: the bot commit; production: a PR back to the previous tag) |

Release tags are immutable: CI never rebuilds an existing `X.Y.Z`. Each repo's **Deployments** tab shows what
runs in each environment; its **Releases** tab has the images and the values to paste.

## Configure

| Task | How |
|---|---|
| Change a setting | `env:` in the app's `values.yaml`. Never secrets (the lint workflow rejects them) |
| Change a secret | Edit it in Infisical. The Secret updates within a minute and the pods restart |
| Add a secret | Add it to `/online-judge/core`: `core/` loads every key there. Other apps need a `secretKeyRef` |
| Add a hostname | PR to `terraform-cloudflare` (`zero-trust/tunnel/tunnels/control-plane-<env>.yaml`) |
| Add a service | Add `clusters/<env>/<namespace>/<app>/`; the ApplicationSet creates the app `<namespace>-<app>` |
| Change chart options | Every app uses `oci://ghcr.io/tloi-dalat/charts/app`, pinned in its `kustomization.yaml` |
| Change k3s settings | `bootstrap/<env>/k3s-config.yaml` → `/etc/rancher/k3s/config.yaml`, restart k3s. Never `disable-network-policy`: it confines the judges |

## Scale

- Site: autoscales in production (`autoscaling` in `core/site.yaml`). Raise `minReplicas` before a big contest.
- Judges: change `replicaCount` in `judge/values.yaml` and register or remove `judge-<n>` in the site admin.
  Keep it within the cores the VPS can spare, or time limits get unfair.
- Bridge, wsevent and redis stay at one replica.
- Judges: `JUDGE__INDEX` must sort before `JUDGE__NAME` in `env` (the chart sorts env by name).

## Look around

```bash
kubectl -n argocd get applications
kubectl -n online-judge get pods
kubectl -n online-judge logs deploy/online-judge-site --tail=50
kubectl -n online-judge logs job/online-judge-site-migrate
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite   # sync now
```

## Database

Development: mariadb-operator in `clusters/development/database/` (`mariadb-operator/`, `mariadb/`). Apps write to
`mariadb-primary.database.svc.cluster.local`; SQL Lab reads `mariadb-secondary` (the replica). Production: MariaDB on
the host, `10.42.0.1`.

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
| Restore | A `Restore` with `backupRef: { name: daily }`; it overwrites the live tables |
| PostgreSQL | `database/cnpg/` (operator, CRDs included) and `database/postgres/` |

## SQL Lab

`sqllab.tloi.shop` (development): DbGate on the replica as read-only user `sqllab`, behind Cloudflare Access.

| Task | How |
|---|---|
| Allow an email | terraform-cloudflare, `control-plane-<env>.yaml` → `access.<hostname>.emails` |
| Show another database | A `Grant` like `sqllab-online-judge` in `database/mariadb/sqllab.yaml` |

## Data

- Media and problem data: `/home/tloi/data/online-judge`. Development database: `/home/tloi/data/database`, backed
  up daily to R2 (`backup.yaml`). Production database: on the host, back it up separately.
- Volumes are local PVs ArgoCD never deletes. A PV's path can't change; moving data means a new PV and PVC. Review
  any PR that touches `storage/`.
- No secrets in git: values live in Infisical, this repo only maps folders to Secrets.
