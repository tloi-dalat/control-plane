# Bootstrap: dev cluster on the dev VPS

From the dev VPS as it is today (supervisor stack serving `oj-dev.tloi.vn`) to the same site running on
k3s + ArgoCD **alongside** it, then a cutover that takes seconds and rolls back in seconds.
The old stack keeps serving until step 12.

Each step ends with a **check**. Don't move on until it passes.

Versions pinned here: k3s `v1.36.5+k3s1`, ArgoCD `v3.5.3`, Infisical operator `v0.11.9`,
cloudflared `2026.9.3`.

---

## 0. Before touching the VPS

1. **Push the repos in this order**, since each depends on the previous one:
   1. `tloi-dalat/reusable-workflow`. It must be **public**: the app repos calling it are public, and
      GitHub doesn't let a public repo call workflows in a private one.
   2. `tloi-dalat/charts`. Its workflow publishes `charts/app:0.1.0`. Then on GHCR, set the package
      **public**, because ArgoCD pulls it without credentials.
   3. `tloi-dalat/control-plane` (this repo, private).
2. **Secrets for CI**: create `CONTROL_PLANE_TOKEN` (fine-grained PAT, *Contents: read & write* on
   `control-plane` only) as an org secret, or in both `TLOJ` and `judge-server`.
3. **Merge the `feat/k8s-dev` branches** in `TLOJ` and `judge-server`. Their first `main` builds push
   `oj-core`, `oj-wsevent` and `oj-judge` to GHCR, then commit tag bumps here, replacing `main-0000000`.
   Set the three packages **public** (or add an image pull secret).
   *Check:* `git log` here shows `[BOT] dev/online-judge: …` commits; `grep -rn main-0000000 clusters/` is empty.
4. **Rotate the Google OAuth client secret** (the old one appeared in a chat transcript). Add both
   redirect URIs to the client: `https://oj-dev-k8s.tloi.vn/complete/google-oauth2/` and
   `https://oj-dev.tloi.vn/complete/google-oauth2/`.
5. **Fill in the `CHANGEME`s** that need the VPS: paths and UID. On the VPS:
   ```bash
   id tloi                                    # → runAsUser / runAsGroup
   grep -n "MEDIA_ROOT\|PROBLEM_DATA_ROOT" /home/tloi/site/dmoj/local_settings.py
   ```
   Put the paths in `clusters/development/online-judge/storage/{media,problems}.yaml` and the IDs in
   `clusters/development/online-judge/core/values.yaml` and `clusters/development/online-judge/media/values.yaml`. Commit.

## 1. Prepare the VPS

```bash
git clone https://github.com/tloi-dalat/control-plane.git ~/control-plane   # or via deploy key
cd ~/control-plane
free -h          # expect ~8 GB
```

## 2. MySQL: reachable from pods, nowhere else

Pods reach the host at `10.42.0.1` (MYSQL__HOST in `clusters/development/online-judge/core/values.yaml`), so MySQL must listen
beyond loopback, and the firewall must allow **only** the pod network.

```bash
# /etc/mysql/mysql.conf.d/mysqld.cnf (or mariadb.conf.d/50-server.cnf):
#   bind-address            = 0.0.0.0
#   innodb_buffer_pool_size = 1G      # explicit, so it can't grow into the pods' memory
sudo systemctl restart mysql

# ufw (if you use another firewall, apply the same policy there).
sudo ufw allow OpenSSH                                          # first, so you can't lock yourself out
sudo ufw allow from 10.42.0.0/16 comment 'k3s pods'
sudo ufw allow from 10.43.0.0/16 comment 'k3s services'
sudo ufw deny 3306/tcp
sudo ufw enable

# Dedicated user for pods: edit the password in the file, run it, then remove it from the file.
sudo mysql < bootstrap/development/mysql-k8s-user.sql
```

**Check:** `sudo ss -ltnp | grep 3306` shows `0.0.0.0:3306`. From **your laptop**,
`nc -vz -w3 <vps-public-ip> 3306` must **fail**. The old stack still works (it uses 127.0.0.1).

## 3. k3s

```bash
sudo mkdir -p /etc/rancher/k3s
sudo cp bootstrap/development/k3s-config.yaml /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.36.5+k3s1' sh -
mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config \
  && sudo chown "$USER" ~/.kube/config && chmod 600 ~/.kube/config
```

**Check:**
```bash
kubectl get nodes --show-labels | grep tloi.vn/data-node=true          # node Ready, labelled
kubectl run dbcheck --rm -it --restart=Never --image=mysql:8.0 -- \
  mysql -h 10.42.0.1 -u dmoj_k8s -p -e 'SELECT 1'                      # pods reach MySQL
```

## 4. ArgoCD

```bash
kubectl apply --server-side --force-conflicts -k bootstrap/development/argocd
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

The UI is **never exposed publicly**. Reach it through SSH:
`ssh -L 8080:localhost:8080 <vps>`, then on the VPS `kubectl -n argocd port-forward svc/argocd-server 8080:443`,
then open https://localhost:8080 (user `admin`). Change the password, then delete `argocd-initial-admin-secret`.

If this repo is private, add read access now: follow `bootstrap/development/argocd/repo-credentials.example.yaml`.

**Check:** `kubectl -n argocd get cm argocd-cm -o yaml | grep enable-helm`.

## 5. Hand the cluster to git

```bash
kubectl apply -f clusters/development/application-set.yaml
kubectl -n argocd get applications -w
```

`infisical-operator` goes Healthy first. The `online-judge-*` apps keep retrying until the
Infisical login and its secrets exist (step 7). That's expected.

## 6. (removed: there is no sealed-secrets key to back up any more)

## 7. Tunnel and secrets

**The tunnel lives in `tloi-dalat/terraform-cloudflare`.** Its `zero-trust/tunnel/tunnels/control-plane-development.yaml`
lists the hostnames and routes; merging it creates the tunnel, the DNS records, and writes the tunnel
token into Infisical (`development` → `/cloudflared`), where `cloudflared/tunnel/cloudflared-token.yaml`
picks it up. No `cloudflared` CLI needed. See that repo's README for its one-time setup.

**App secrets live in Infisical** (https://app.infisical.com, free plan):

1. Create a project `TLOI`. Project Settings → Environments: set the slugs to `development` and
   `production` (delete `staging`). Copy the **project slug** into `projectSlug:` in
   `clusters/development/online-judge/secrets/online-judge-core-env.yaml` and `online-judge-judge-env.yaml`.
2. In environment `development`, create folder `/online-judge` with two subfolders, `core` and `judge`.
   `bootstrap/new-app-secrets.sh` prints fresh values: import the first block into `/online-judge/core`
   (fill in `MYSQL__PASSWORD` from step 2 and the **rotated** Google secret), and `JUDGE__KEY` into
   `/online-judge/judge`.
3. Organization → Access Control → Identities → create `tloi-development` (org role: No Access).
   Its Universal Auth → create a Client Secret. In the project → Access Control → Machine Identities →
   add it as **Viewer**.

Then give the cluster its Infisical login, the one credential that can't live in Infisical. It is
not in git: run this once per cluster (again only after a rebuild or to rotate it):

```bash
bootstrap/infisical-login.sh development      # prompts for the tloi-development Client ID + Secret
```

Keep the client secret in your password manager, or just create a new one in Infisical when needed.

- In the dev site admin → **Judges → Add judge**: name `online-judge-judge-0`, key = `JUDGE__KEY` from
  Infisical.
- Commit `online-judge/secrets/` (the project slug), then push.

**Check:** `kubectl -n argocd get applications` shows everything **Synced / Healthy**.
`kubectl -n online-judge get pods`: all Running, `online-judge-site-migrate` Completed.

## 8. Smoke test on https://oj-dev-k8s.tloi.vn

The old stack still serves `oj-dev.tloi.vn`, untouched.

- [ ] Home page and a problem page load, with no 404s in the browser devtools (static files).
- [ ] Log in with a password, then with Google (an OAuth error means a missing redirect URI; dev plan §4.2).
- [ ] Admin → your user: **IP is your real IP**, not `10.42.x.x` (dev plan §4.1).
- [ ] Submit a correct solution: it judges, and the status updates **live** without refreshing (wsevent).
- [ ] An image embedded in a problem statement displays (media path and UID are right).
- [ ] Edit a problem's test data in admin and save (problem volume is writable).
- [ ] **Judge isolation.** Simulate a sandbox escape by opening connections from inside the judge pod:
  ```bash
  j() { kubectl -n online-judge exec online-judge-judge-0 -- timeout 5 bash -c "</dev/tcp/$1/$2" && echo "OPEN  $1:$2" || echo "blocked $1:$2"; }
  j online-judge-bridge 9999          # must be OPEN    (its only job)
  j 10.42.0.1 3306          # must be blocked (MySQL)
  j online-judge-redis 6379           # must be blocked
  j kubernetes.default 443  # must be blocked (API)
  j 1.1.1.1 443             # must be blocked (internet)
  ```
  If anything except the bridge is OPEN, **stop**. The NetworkPolicy isn't enforced; check that k3s
  wasn't started with `disable-network-policy`.

## 9. Cut over

1. PR: in `clusters/development/online-judge/core/values.yaml` set `SITE__DOMAIN: oj-dev.tloi.vn`, and in
   in `terraform-cloudflare`'s tunnel file change the `oj.tloi.shop` hostnames to it. Merge both, and wait
   for `online-judge-core` to be Synced.
2. If `oj-dev.tloi.vn` already has a DNS record (the old stack), delete it right before the
   `terraform-cloudflare` apply, or that apply fails on the existing record. Add `tloi.vn` to its `zones`.
3. Re-run the step 8 checklist on https://oj-dev.tloi.vn. Everyone is logged out once (new `SECRET_KEY`).

**Rollback:** point `oj-dev.tloi.vn` back at the old stack in the Cloudflare dashboard (after removing it from the tunnel file). That takes seconds,
because the old stack never stopped.

From here on, merges to `main` deploy to **both** dev stacks (old: `deploy.yml` over SSH; new: ArgoCD)
against the same database, which is safe because they run the same commit.

## 10. Daily backups

Install the backup job from the design doc §11.4 (systemd timer, `mysqldump` and `restic` off-site),
pointed at the paths in `clusters/development/online-judge/storage/`. Then **restore once**, deliberately, to prove it works.

## 11. After a quiet week: remove the old stack

- `sudo supervisorctl stop all`, then disable supervisor's site, bridged, celery and wsevent programs; disable the
  host nginx site and the old cloudflared service.
- Remove the `deploy2qa` job from `TLOJ/.github/workflows/deploy.yml` and `judge-server/.github/workflows/deploy.yml`,
  and delete `update_tloj.sh` / `update_judge.sh` on the dev VPS. Leave the prd jobs alone.
- Stop the old Docker judge. Drop the old MySQL user once nothing uses it.
- Delete the test hostname's DNS record.

## Disaster recovery (dev VPS lost)

New VPS → restore MySQL and the media/problem directories from restic → steps 1–4 →
step 5 → `bootstrap/infisical-login.sh development` (step 7). ArgoCD redeploys everything from git,
and the app secrets come back from Infisical: nothing else needs re-entering.
