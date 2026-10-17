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

## Scale

- Site: autoscales in production (`autoscaling` in `core/site.yaml`). Raise `minReplicas` before a big contest.
- Judges: change `replicaCount` in `judge/values.yaml` and register or remove `judge-<n>` in the site admin.
  Keep it within the cores the VPS can spare, or time limits get unfair.
- Bridge, wsevent and redis stay at one replica.

## Look around

```bash
kubectl -n argocd get applications
kubectl -n online-judge get pods
kubectl -n online-judge logs deploy/online-judge-site --tail=50
kubectl -n online-judge logs job/online-judge-site-migrate
kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite   # sync now
```

## Data

Media and problem data live in `/home/tloi/data/online-judge` on the node; the database runs on the host.
Back up both. The volumes are never deleted by ArgoCD, but review any PR that touches `storage/`.
