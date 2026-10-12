# control-plane

GitOps source of truth for every TLOI service. ArgoCD runs inside each cluster, watches this repo,
and makes the cluster match it. Merging to `main` is how things get deployed. CI never touches
a cluster; its only write is a bot commit here that bumps an image tag.

Same shape as Cake's `control-plane`, rebuilt for TLOI.

```
tloi-dalat/TLOJ, judge-server  ──build──▶  ghcr.io/tloi-dalat/oj-*:main-<sha>
        │ repository_dispatch "sync-version"
        ▼
control-plane  ── bot commit: clusters/development/online-judge/<app>/values.yaml image.tag ──▶  ArgoCD (in cluster) syncs
```

## Layout

```
clusters/
  development/                    ← dev VPS. Production (clusters/production/) is not here yet.
    application-set.yaml          ← one ArgoCD app per directory below (applied once at bootstrap)
    kube-system/sealed-secrets/   ← decrypts committed SealedSecrets (Infisical login, tunnel credentials)
    cloudflared/tunnel/           ← the only way in, for every namespace: Cloudflare Tunnel connector (routes + DNS: terraform-cloudflare)
    infisical/                    ← namespace "infisical"
      operator/  Infisical Secrets Operator: Infisical Cloud → Kubernetes Secrets
      auth/      its login (machine identity, sealed) — shared by every namespace
    online-judge/                 ← namespace "online-judge"
      core/      site + bridge + celery: one image, shared values.yaml, migrate PreSync hook
      wsevent/   live-update daemon
      judge/     DMOJ judge (StatefulSet, ptrace sandbox, egress-only NetworkPolicy)
      media/     nginx serving user uploads read-only
      redis/     cache + celery broker
      (MariaDB runs on the VPS host; pods use 10.42.0.1, see core/values.yaml)
      storage/   PVs for media + problem data (existing dirs on the VPS; Retain, never pruned)
      secrets/   which Infisical folders become which Secrets, + the sealed tunnel credentials
bootstrap/
  development/README.md           ← runbook: from a bare VPS to a running cluster
  seal-secrets.sh                 ← seals the Infisical login / tunnel credentials
  new-app-secrets.sh              ← random app secrets for a NEW environment, to paste into Infisical
```

App names are `<namespace>-<dir>` (e.g. `online-judge-core`), and resources are named after the Helm release
(`online-judge-site`, `online-judge-bridge`, …). Adding a service later, say `quiz`, means adding `clusters/development/quiz/<app>/`. The
ApplicationSet picks it up without any change.

## Common changes

| I want to… | Do this |
|---|---|
| Deploy a new version | Nothing. Merge to `main` in the app repo; CI commits the tag bump here |
| Roll back | `git revert` the bot commit (or set `image.tag` to the previous `main-<sha>`) and merge |
| Change a setting | Edit `env:` in the app's `values.yaml`. **Non-secret values only**, which CI enforces |
| Change a secret | Edit it in Infisical (project TLOJ → environment → folder `/online-judge/core`, or `/online-judge/judge` for the judge key). The Secret updates within a minute and the pods restart themselves. No commit |
| Add a secret | Add it in Infisical. `core/` (site, bridge, celery) gets every key in `/online-judge/core` via `envFrom`; other apps need a `secretKeyRef` to `online-judge-core-env` |
| Change routing / add a hostname | PR to `tloi-dalat/terraform-cloudflare`: `zero-trust/tunnel/tunnels/control-plane-development.yaml` |
| Scale | `replicaCount` (site only; bridge, wsevent and redis must stay at 1) |

Every app uses the shared chart `oci://ghcr.io/tloi-dalat/charts/app`, pinned in each
`kustomization.yaml`. All chart options are in the `tloi-dalat/charts` repo.

## Values to fill in before first deploy

`grep -rn CHANGEME clusters/` lists them all:

| Where | What |
|---|---|
| `online-judge/storage/{media,problems}.yaml` | the existing media and problem-data directories on the dev VPS |
| `online-judge/{core,media}/values.yaml` | UID/GID owning those directories (`id tloi`) |
| `online-judge/secrets/online-judge*-env.yaml` | the Infisical project slug (Project Settings) |
| `online-judge/{core,wsevent,judge}/values.yaml` | `image.tag`, set by the first CI deploy |

## Rules

- **No plaintext secrets**, anywhere. Settings go in `values.yaml`; secrets go in Infisical (or, for the
  two bootstrap credentials, SealedSecrets).
  `.gitignore` blocks key and credential files, and the lint workflow rejects secret-looking literals.
- **Volumes are never pruned.** PVs use `Retain` plus `Prune=false,Delete=false`. Removing a directory
  here won't delete data, but double-check any PR that touches `storage/`.
- **Pin versions**: chart versions and image tags, never `latest`.
