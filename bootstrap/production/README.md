# Bootstrap: production cluster

Production is built exactly like development: follow [`../development/README.md`](../development/README.md)
from step 1 on the **production VPS**, reading `production` wherever it says `development`. This page
lists only what differs. Nothing here touches the dev cluster.

## Before touching the VPS

1. **Release tags exist.** Production runs release tags only (`X.Y.Z`), never `main-<sha>`. In both
   `TLOJ` and `judge-server`: create the `release` branch from `main` and push it (or merge `main` into
   it). `release.yaml` tags `0.0.0`, builds `oj-core`, `oj-wsevent`, `oj-judge` as `:0.0.0`, and the
   build's run summary prints the `image:` blocks to paste below.
2. **Fill in every `CHANGEME`** under `clusters/production/` (`grep -rn CHANGEME clusters/production`):

   | Where | What |
   |---|---|
   | `online-judge/{core,wsevent,judge}/values.yaml` | `image.tag`: the release to run. `core` and `wsevent` always carry the **same** tag |
   | `online-judge/core/values.yaml` | `SITE__DOMAIN`, `DJANGO__REGISTRATION_OPEN`, `MYSQL__HOST` (if MariaDB is not on the VPS host), SMTP `MAIL__*`, `SOCIAL__GOOGLE_KEY` |
   | `online-judge/core/site.yaml` | `autoscaling.maxReplicas` for the VPS size |
   | `online-judge/{core,media}/values.yaml` | UID/GID owning the data directories (`id tloi` on the production VPS) |
   | `online-judge/storage/{media,problems}.yaml` | the media and problem-data directories on the production VPS |

3. **Tunnel**: in `tloi-dalat/terraform-cloudflare`, add `zero-trust/tunnel/tunnels/control-plane-production.yaml`
   (copy the development one, production hostnames; Infisical environment `production`, folder `/cloudflared`).
4. **Google OAuth**: add `https://<SITE__DOMAIN>/complete/google-oauth2/` to the client's redirect URIs.

## Differences in the runbook

| Step | Development | Production |
|---|---|---|
| 2. MySQL | `bootstrap/development/mysql-k8s-user.sql` | `bootstrap/production/mysql-k8s-user.sql` (its own password) |
| 3. k3s | `bootstrap/development/k3s-config.yaml` | `bootstrap/production/k3s-config.yaml` (adjust `system-reserved` to the VPS) |
| 4. ArgoCD | `-k bootstrap/development/argocd` | `-k bootstrap/production/argocd` |
| 5. ApplicationSet | `clusters/development/application-set.yaml` | `clusters/production/application-set.yaml` |
| 7. Infisical | environment `development`, identity `tloi-development` | environment `production`, folders `/online-judge/core` (+ `MAIL__PASSWORD`) and `/online-judge/judge`, identity `tloi-production` (Viewer). Fresh values from `bootstrap/new-app-secrets.sh` — never reuse dev's |
| 7. Login | `bootstrap/infisical-login.sh development` | `bootstrap/infisical-login.sh production` (check the kubectl context it prints) |
| Judge | `judge-0` in the dev site admin | five judges: `judge-0` … `judge-4` in the production site admin, all with the production `JUDGE__KEY` (snippet below) |

Register the five judges in one go (from a machine with kubectl on the production cluster):

```bash
KEY=$(kubectl -n online-judge get secret online-judge-judge-env -o jsonpath='{.data.JUDGE__KEY}' | base64 -d)
kubectl -n online-judge exec deploy/online-judge-site -- env K="$KEY" python manage.py shell -c "
import os; from judge.models import Judge
for i in range(5): Judge.objects.get_or_create(name=f'judge-{i}', defaults={'auth_key': os.environ['K']})"
```

**Check:** `kubectl -n argocd get applications` shows everything **Synced / Healthy**, and
`kubectl -n online-judge get pods -o jsonpath='{..image}'` shows `:X.Y.Z` images only.
