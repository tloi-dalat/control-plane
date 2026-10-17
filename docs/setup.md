# Set up a new VPS

Builds a cluster for `development` or `production` on a fresh VPS (Ubuntu 24.04). Everything runs on one node;
MySQL/MariaDB stays on the host, outside Kubernetes.

| | development | production |
|---|---|---|
| Site | `oj.tloi.shop` | `oj.tloi.vn` |
| Webhook host | `argocd-hook.tloi.shop` | `argocd-hook.tloi.vn` |
| k3s config | `bootstrap/development/k3s-config.yaml` | `bootstrap/production/k3s-config.yaml` |
| Judges | 1 | 5 |

Pinned versions: k3s `v1.36.5+k3s1`, ArgoCD `v3.5.3`.

## 1. Host

```bash
id tloi                                   # uid/gid must be 1001 (runAsUser in core/ and media/ values.yaml)
sudo mkdir -p /home/tloi/data/online-judge/{media,problems}
sudo chown -R 1001:1001 /home/tloi/data
git clone https://github.com/tloi-dalat/control-plane.git ~/control-plane && cd ~/control-plane
```

Moving from another server: copy `media` and `problems` into those directories first.

## 2. Database

Install MariaDB (or MySQL), create the `dmoj` database, or restore a dump into it.

Let pods connect. Pods reach the host at `10.42.0.1`, so the server must listen on all addresses:

```bash
# MariaDB: /etc/mysql/mariadb.conf.d/60-k8s.cnf    MySQL: /etc/mysql/mysql.conf.d/z-k8s.cnf
printf '[mysqld]\nbind-address = 0.0.0.0\ninnodb_buffer_pool_size = 1G\nskip-name-resolve\n' \
  | sudo tee /etc/mysql/mariadb.conf.d/60-k8s.cnf
sudo systemctl restart mariadb
sudo ss -ltnp | grep 3306                 # 0.0.0.0:3306
```

Leave out `skip-name-resolve` while anything still logs in as `user@localhost` over TCP.

Allow only the pod networks to reach it:

```bash
sudo apt install -y ufw
sudo ufw allow OpenSSH
sudo ufw allow from 10.42.0.0/16
sudo ufw allow from 10.43.0.0/16
sudo ufw deny 3306/tcp
sudo ufw enable
```

From another machine, `nc -vz -w3 <vps-ip> 3306` must fail.

Create the pod user, with a new password you keep for Infisical:

```bash
sudo mysql -e "CREATE USER IF NOT EXISTS 'dmoj_k8s'@'10.42.%' IDENTIFIED BY '<password>';
  GRANT ALL PRIVILEGES ON dmoj.* TO 'dmoj_k8s'@'10.42.%'; FLUSH PRIVILEGES;"
```

## 3. k3s

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cp bootstrap/<env>/k3s-config.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.36.5+k3s1' sh -
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config \
  && sudo chown "$USER" ~/.kube/config && chmod 600 ~/.kube/config
kubectl get nodes                         # Ready
```

Adjust `system-reserved` in the k3s config to what runs outside Kubernetes (database, mailcow, Docker).
If the host uses systemd-resolved (`nameserver 127.0.0.53`), keep `resolv-conf` as in the production config.

## 4. ArgoCD

```bash
kubectl apply --server-side --force-conflicts -k bootstrap/argocd
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

The UI is never public. Reach it over SSH: `ssh -L 8080:localhost:8080 <vps>`, then on the VPS
`kubectl -n argocd port-forward svc/argocd-server 8080:443`, and open https://localhost:8080 as `admin`.
Change the password, then delete `argocd-initial-admin-secret`.

If `control-plane` is private, add it under Settings → Repositories (GitHub App credentials).

Hand the cluster to git:

```bash
kubectl apply -f clusters/<env>/application-set.yaml
kubectl -n argocd get applications -w
```

The `online-judge-*` and `cloudflared` apps retry until step 5 is done.

## 5. Secrets and tunnel

In Infisical (project TLOI, environment `<env>`):

| Folder | Keys |
|---|---|
| `/online-judge/core` | `DJANGO__SECRET_KEY`, `MYSQL__PASSWORD`, `REDIS__PASSWORD`, `SOCIAL__GOOGLE_SECRET`, `EVENT__SUBMISSION_KEY`, `EVENT__CONTEST_KEY`, `EVENT__TICKET_KEY`; production also `MAIL__PASSWORD`, `POLYGON__API_KEY`, `POLYGON__API_SECRET`, `MOSS__API_KEY`, `DISCORD__*` |
| `/online-judge/judge` | `JUDGE__KEY` |

- A brand-new environment: `bootstrap/new-app-secrets.sh` prints random values.
- Moving an existing environment: keep its values. A new `DJANGO__SECRET_KEY` logs everyone out and breaks stored 2FA.

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

## 6. Judges

Register `judge-0` … `judge-<n-1>` (n from the table above):

```bash
KEY=$(kubectl -n online-judge get secret online-judge-judge-env -o jsonpath='{.data.JUDGE__KEY}' | base64 -d)
kubectl -n online-judge exec deploy/online-judge-site -- env K="$KEY" N=5 python manage.py shell -c "
import os; from judge.models import Judge
for i in range(int(os.environ['N'])): Judge.objects.get_or_create(name=f'judge-{i}', defaults={'auth_key': os.environ['K']})"
```

The judge must reach only the bridge:

```bash
j() { kubectl -n online-judge exec online-judge-judge-0 -- timeout 5 bash -c "</dev/tcp/$1/$2" && echo "OPEN $1:$2" || echo "blocked $1:$2"; }
j online-judge-bridge 9999; j 10.42.0.1 3306; j online-judge-redis 6379; j kubernetes.default 443; j 1.1.1.1 443
```

Anything other than the bridge OPEN: stop. Network policy isn't enforced.

## 7. ArgoCD webhook

Syncs a merge within seconds instead of the 3-minute poll.

```bash
SECRET=$(openssl rand -hex 32); echo "$SECRET"
kubectl -n argocd patch secret argocd-secret --type merge -p "{\"stringData\":{\"webhook.github.secret\":\"$SECRET\"}}"
```

GitHub → `control-plane` → Settings → Webhooks → Add: `https://<webhook host>/api/webhook`,
`application/json`, that secret, push events only. Recent Deliveries should show `200`.

## 8. Mail (production)

The site sends through mailcow on the same host as `no-reply@tloi.vn` (an SMTP-only app password in
`MAIL__PASSWORD`). Pods can't reach the VPS's public IP, so `core/kustomization.yaml` maps `mail.tloi.vn` to
`10.42.0.1`. Mailcow needs:

- `DISABLE_NETFILTER_ISOLATION_RULE=y` in `mailcow.conf`, or its firewall drops connections from pods.
- `MAILCOW_HOSTNAME=mail.tloi.vn`, `HTTP_PORT=80` open to the internet, and `SKIP_HTTP_VERIFICATION=y`, so it gets a Let's Encrypt certificate.

Test from a pod:

```bash
kubectl -n online-judge exec -i deploy/online-judge-site -- python - <<'PY'
import os, smtplib, ssl
s = smtplib.SMTP(os.environ['MAIL__HOST'], int(os.environ['MAIL__PORT']), timeout=10)
s.ehlo(); s.starttls(context=ssl.create_default_context()); s.ehlo()
s.login(os.environ['MAIL__USER'], os.environ['MAIL__PASSWORD']); print('login ok'); s.quit()
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

New VPS: restore the `dmoj` database and `/home/tloi/data` from backup, then steps 1–5. ArgoCD redeploys
everything else from git and the secrets come back from Infisical.
