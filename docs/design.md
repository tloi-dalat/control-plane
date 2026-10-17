# Design notes

Why things are the way they are. Read before changing any of these.

## Cluster

- One node per environment. MySQL/MariaDB runs on the host; pods reach it at `10.42.0.1` (the host's address on
  the pod bridge) as `dmoj_k8s`, allowed only from `10.42.%`.
- Nothing listens on a public port. All traffic comes through the Cloudflare tunnel; its routes and DNS live in
  `terraform-cloudflare`, this repo only runs the connector.
- k3s: traefik and servicelb off; `flannel-backend: host-gw` (no VXLAN port); the node label
  `tloi.vn/data-node=true` pins the data volumes. Never set `disable-network-policy`: the NetworkPolicy
  controller is what confines the judge.
- Production shares the host with Docker (mailcow, CTF containers). Docker must never use `10.42.0.0/16` or
  `10.43.0.0/16`. `system-reserved` keeps memory for everything outside Kubernetes. The host uses
  systemd-resolved, so k3s reads `/run/systemd/resolve/resolv.conf` (CoreDNS can't use `127.0.0.53`).
- ArgoCD runs with `kustomize.buildOptions: --enable-helm`: every app is a kustomization with `helmCharts`.

## Online judge

- `core/` is one ArgoCD app for site, bridge and celery: one image, one tag. The `migrate` PreSync hook runs
  before any of them update, so none meets a schema it doesn't expect. A failed migration stops the sync and the
  old pods keep serving.
- Site probes are TCP, not HTTP: kubelet sends the pod IP as `Host`, which `ALLOWED_HOSTS` rejects.
- Exactly one bridge (`Recreate`): judges and site must reach the same one. One wsevent: its message queue is in
  memory. Redis has no persistence and uses `volatile-lru`, which evicts cache keys only, never the Celery queue.
- Pods run as uid/gid 1001, the owner of the data directories. No `fsGroup`: kubelet would chown every file on
  each mount.
- Pods restart when Infisical changes a secret they read (annotation `secrets.infisical.com/auto-reload`).
- Production: `DJANGO__SECRET_KEY` is the old site's key, so sessions and stored 2FA secrets keep working.
- Production: `mail.tloi.vn` is mapped to `10.42.0.1` (`hostAliases`), because pods can't reach the VPS's public IP.
- Password-reset mail is sent from `SERVER_EMAIL` (`MAIL__SERVER_EMAIL`), not `DEFAULT_FROM_EMAIL`.

## Judge isolation

The judge runs untrusted code on the same node as everything else. Its controls:

- cptbox sandbox (ptrace + seccomp). The pod starts as root with `SYS_PTRACE` and an unconfined seccomp profile;
  the entrypoint drops to the `judge` user, and cptbox installs its own filter per process.
- NetworkPolicy: only the bridge (9999) and DNS. Not the database, Redis, the API server or the internet.
- No ServiceAccount token, problem data read-only, a Secret holding only `JUDGE__KEY`.
- StatefulSet: pods register as `judge-<pod-index>`. `JUDGE__INDEX` must sort before `JUDGE__NAME` in `env`,
  because the chart renders env sorted by name and `JUDGE__NAME` expands it.
- Fixed replica count, no autoscaling: removing a judge mid-grade fails that submission.

Uploads: the media nginx sends SVGs with a sandbox CSP, so a scripted SVG opened directly can't run on the
site's origin.

## Data and secrets

- Volumes are local PVs with `Retain` and `Prune=false,Delete=false`: ArgoCD never deletes them. A local PV's
  path can't change once it exists; moving the data means recreating the PV and PVC.
- No secrets in git. Values live in Infisical; this repo only maps folders to Secrets. The one credential outside
  Infisical is its own login (Secret `infisical/infisical-bootstrap`, from `bootstrap/infisical-login.sh`).
