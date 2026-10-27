# Set up a new VPS

Builds a cluster for `development` or `production` on a fresh VPS (Ubuntu 24.04). Everything runs on one node,
the database included (`operations.md` § Database).

| | development | production |
|---|---|---|
| Site | `oj.tloi.shop` | `oj.tloi.vn` |
| Webhook host | `argocd-hook.tloi.shop` | `argocd-hook.tloi.vn` |
| ArgoCD UI | `argocd.tloi.shop` | `argocd.tloi.vn` |
| SQL Lab | `sqllab.tloi.shop` | `sqllab.tloi.vn` |
| Newsletter (listmonk) | | `send.tloi.vn` |
| Short links (Shlink) | | `link.tloi.vn`, dashboard `link-admin.tloi.vn` |
| k3s config | `bootstrap/development/k3s-config.yaml` | `bootstrap/production/k3s-config.yaml` |
| Judges | 1 | 5 |

Pinned versions: k3s `v1.36.5+k3s1`, ArgoCD `v3.5.3`.

## 1. Host

```bash
id tloi                                   # uid/gid must be 1001 (runAsUser in site/ and media/ values.yaml)
sudo mkdir -p /home/tloi/data/online-judge/{media,problems}
sudo chown -R 1001:1001 /home/tloi/data
sudo install -d -o 999 -g 999 /home/tloi/data/database/mariadb-{0,1}
sudo install -d /home/tloi/data/platform/sqllab
# production only:
sudo install -d -o 26 -g 26 /home/tloi/data/database/postgres-{1,2}
sudo install -d -o 1000 -g 2000 /home/tloi/data/monitoring/prometheus
sudo install -d -o 1001 -g 1001 /home/tloi/data/platform/newsletter
```

Moving from another server: copy `media` and `problems` into those directories first.

## 2. k3s

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cp bootstrap/<env>/k3s-config.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.36.5+k3s1' sh -
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config \
  && sudo chown "$USER" ~/.kube/config && chmod 600 ~/.kube/config
kubectl get nodes                         # Ready
```

Adjust `system-reserved` in the k3s config to what runs outside Kubernetes (mailcow, Docker).
If the host uses systemd-resolved (`nameserver 127.0.0.53`), keep `resolv-conf` as in the production config.

## 3. ArgoCD

```bash
kubectl apply --server-side --force-conflicts -k bootstrap/argocd
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

The UI (table above) is read-only for anyone Cloudflare Access lets in. To change things, log in as `admin`
over SSH: `ssh -L 8080:localhost:8080 <vps>`, then on the VPS
`kubectl -n argocd port-forward svc/argocd-server 8080:443`, and open https://localhost:8080.
Change the password, then delete `argocd-initial-admin-secret`.

If `control-plane` is private, add it under Settings → Repositories (GitHub App credentials).

Hand the cluster to git:

```bash
kubectl apply -f clusters/<env>/application-set.yaml
kubectl -n argocd get applications -w
```

Most apps retry until step 4 is done.

## 4. Secrets and tunnel

In Infisical (project TLOI, environment `<env>`):

| Folder | Keys |
|---|---|
| `/online-judge/site` | `SECRET_KEY`, `DATABASE_PASSWORD`, `REDIS_PASSWORD`, `SOCIAL_AUTH_GOOGLE_OAUTH2_KEY`, `SOCIAL_AUTH_GOOGLE_OAUTH2_SECRET`, `EVENT_DAEMON_SUBMISSION_KEY`, `EVENT_DAEMON_CONTEST_KEY`, `EVENT_DAEMON_TICKET_KEY`; optional `FERNET_KEYS` (older keys for 2FA data); production also `EMAIL_HOST_PASSWORD`, `VNOJ_POLYGON_API_KEY`, `VNOJ_POLYGON_API_SECRET`, `MOSS_API_KEY`, `DISCORD_WEBHOOK_*` |
| `/online-judge/judge` | `DMOJ_JUDGE_KEY` |
| `/database/mariadb` | `MARIADB_ROOT_PASSWORD`, `MARIADB_REPL_PASSWORD`, `ONLINE_JUDGE_PASSWORD` (= `/online-judge/site` → `DATABASE_PASSWORD`), `SQLLAB_PASSWORD`; production also `BACKUP_PASSWORD` |
| `/backup` (production) | `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` (R2 token for bucket `tloi-backups`), `RESTIC_PASSWORD` (encrypts file backups; keep a copy outside Infisical) |
| `/monitoring/prometheus` (production) | `DISCORD_WEBHOOK_ALERT_URL` (alerts), `DISCORD_WEBHOOK_SLACK_REPORT_URL` (reports: a webhook URL ending in `/slack`), `DISCORD_ALERT_PREFIX` (text before every alert, e.g. a role mention `<@&role-id>`; can be empty), `DISCORD_ALERT_FIRING_PREFIX` / `DISCORD_ALERT_RESOLVED_PREFIX` (title icon, a Unicode emoji; can be empty), `DISCORD_REPORT_INFO_PREFIX` (report title icon; can be empty), `DISCORD_REPORT_PREFIX` (text before every report, e.g. a mention; can be empty) |
| `/database/postgres` (production) | `NEWSLETTER_PASSWORD`, `URL_SHORTENER_PASSWORD`, `SQLLAB_PASSWORD`, `BACKUP_PASSWORD` |
| `/platform/sqllab` | development: `PASSWORD_replica`; production: `PASSWORD_mariadb` (= `/database/mariadb` → `SQLLAB_PASSWORD`), `PASSWORD_postgres` (= `/database/postgres` → `SQLLAB_PASSWORD`) |
| `/platform/newsletter` (production) | `LISTMONK_db__password` (= `/database/postgres` → `NEWSLETTER_PASSWORD`), `LISTMONK_ADMIN_PASSWORD` (first start only) |
| `/platform/url-shortener` (production) | `DB_PASSWORD` (= `/database/postgres` → `URL_SHORTENER_PASSWORD`), `INITIAL_API_KEY` (Shlink API key, also used by the dashboard); optional `GEOLITE_LICENSE_KEY` (visit locations) |

- Keys are named after the Django setting they set (`.k8s.settings.py` in the site repo).
- A brand-new environment: `bootstrap/new-app-secrets.sh` prints random values.
- Keys that must equal another key: use an Infisical reference (`${/online-judge/site.DATABASE_PASSWORD}`).
- Moving an existing environment: keep its values. A new `SECRET_KEY` logs everyone out and breaks stored 2FA.

Give the cluster its Infisical login (machine identity `tloi-<env>`, Viewer on the project):

```bash
bootstrap/infisical-login.sh <env>       # check the kubectl context it prints
```

The tunnel and its DNS records come from `tloi-dalat/terraform-cloudflare`
(`zero-trust/tunnel/tunnels/control-plane-<env>.yaml`); its apply writes the tunnel token to Infisical
`<env>` → `/cloudflared`. A new hostname that already has a DNS record: delete the record right before the apply.

Check:

```bash
kubectl get infisicalstaticsecrets -A     # all synced
kubectl -n argocd get applications        # all Synced / Healthy
kubectl -n online-judge get pods          # migrate Completed, everything else Running
```

Moving an existing environment: restore the database with a `Restore` (`operations.md` § Database) before the
site starts taking traffic.

## 5. Judges

Register `judge-0` … `judge-<n-1>` (n from the table above):

```bash
KEY=$(kubectl -n online-judge get secret judge-env -o jsonpath='{.data.DMOJ_JUDGE_KEY}' | base64 -d)
kubectl -n online-judge exec deploy/site -- env K="$KEY" N=5 python manage.py shell -c "
import os; from judge.models import Judge
for i in range(int(os.environ['N'])): Judge.objects.get_or_create(name=f'judge-{i}', defaults={'auth_key': os.environ['K']})"
```

The judge must reach only the bridge:

```bash
j() { kubectl -n online-judge exec judge-0 -- timeout 5 bash -c "</dev/tcp/$1/$2" && echo "OPEN $1:$2" || echo "blocked $1:$2"; }
j bridge 9999; j mariadb-primary.database 3306; j redis 6379; j kubernetes.default 443; j 1.1.1.1 443
```

Anything other than the bridge OPEN: stop. Network policy isn't enforced.

## 6. ArgoCD webhook

Syncs a merge within seconds instead of the 3-minute poll.

```bash
SECRET=$(openssl rand -hex 32); echo "$SECRET"
kubectl -n argocd patch secret argocd-secret --type merge -p "{\"stringData\":{\"webhook.github.secret\":\"$SECRET\"}}"
```

GitHub → `control-plane` → Settings → Webhooks → Add: `https://<webhook host>/api/webhook`,
`application/json`, that secret, push events only. Recent Deliveries should show `200`.

## 7. Mail (production)

The site sends through mailcow on the same host as `no-reply@tloi.vn` (an SMTP-only app password in
`EMAIL_HOST_PASSWORD`). Pods can't reach the VPS's public IP, so `site/kustomization.yaml` maps `mail.tloi.vn` to
`10.42.0.1`. Mailcow needs:

- `DISABLE_NETFILTER_ISOLATION_RULE=y` in `mailcow.conf`, or its firewall drops connections from pods.
- `MAILCOW_HOSTNAME=mail.tloi.vn`, `HTTP_PORT=80` open to the internet, and `SKIP_HTTP_VERIFICATION=y`, so it gets a Let's Encrypt certificate.

Test from a pod:

```bash
kubectl -n online-judge exec -i deploy/site -- python - <<'PY'
import os, smtplib, ssl
s = smtplib.SMTP(os.environ['EMAIL_HOST'], int(os.environ['EMAIL_PORT']), timeout=10)
s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
s.login(os.environ['EMAIL_HOST_USER'], os.environ['EMAIL_HOST_PASSWORD']); print('login ok'); s.quit()
PY
```

## Smoke test

- Home, a problem and a ranking load; no 404s in the browser devtools.
- Google login works (an error means a missing redirect URI `https://<site>/complete/google-oauth2/`).
- Admin → your user shows your real IP, not `10.42.x.x`.
- A submission is judged and its status updates live.
- An image in a problem statement shows; saving test data on a test problem works.
- Password reset sends an email.

## Disaster recovery

New VPS: steps 1–4, then restore files and databases from R2 (`operations.md` § Backups). ArgoCD redeploys
everything else from git and the secrets come back from Infisical.
