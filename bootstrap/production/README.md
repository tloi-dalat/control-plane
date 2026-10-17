# Bootstrap: production cluster

Production is built exactly like development: follow [`../development/README.md`](../development/README.md)
from step 1 on the **production VPS**, reading `production` wherever it says `development`. This page
lists only what differs. Nothing here touches the dev cluster.

## Before touching the VPS

1. **Release tags exist.** Production runs release tags only (`X.Y.Z`), never `main-<sha>`. In both
   `TLOJ` and `judge-server`: create the `release` branch from `main` and push it (or merge `main` into
   it). `release.yaml` tags `0.0.0`, builds `oj-core`, `oj-wsevent`, `oj-judge` as `:0.0.0`, and the
   build's run summary prints the `image:` blocks to paste below.
2. **Fill in the remaining `CHANGEME`s** (`grep -rn CHANGEME clusters/production bootstrap/production`).
   Already set for the production VPS (Ubuntu 24.04, 12 cores, 32 GiB, shared with mailcow and CTF
   containers): data paths `/home/tloi/media` and `/home/tloi/problem_data` (the old stack's, no copy),
   UID/GID 1001, MariaDB on the host, `maxReplicas: 4`, k3s config. Still open:

   | Where | What |
   |---|---|
   | `online-judge/judge/values.yaml` | `image.tag`, once judge-server has a release (`core`/`wsevent` run `0.0.0`) |
   | `online-judge/core/values.yaml` | SMTP `MAIL__HOST` / `MAIL__USER`, `SOCIAL__GOOGLE_KEY`; `SITE__DOMAIN` is the test hostname until cutover |
   | `bootstrap/production/mysql-k8s-user.sql` | the `dmoj_k8s` password (edit on the VPS only, never commit it) |

3. **Tunnel**: in `tloi-dalat/terraform-cloudflare`, add `zero-trust/tunnel/tunnels/control-plane-production.yaml`
   (copy the development one, production hostnames; Infisical environment `production`, folder `/cloudflared`).
4. **Google OAuth**: add `https://<SITE__DOMAIN>/complete/google-oauth2/` to the client's redirect URIs.

## Differences in the runbook

| Step | Development | Production |
|---|---|---|
| 2. MySQL | `bootstrap/development/mysql-k8s-user.sql` | **Keep the existing MariaDB 10.11** (the old stack's, data already there). Copy `bootstrap/production/60-tloj.cnf` to `/etc/mysql/mariadb.conf.d/` and restart MariaDB (a few seconds), then `bootstrap/production/mysql-k8s-user.sql` (its own password). No `skip-name-resolve` while the old stack runs |
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
