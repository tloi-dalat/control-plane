# control-plane

GitOps source of truth for every TLOI service. ArgoCD runs inside each cluster, watches this repo,
and makes the cluster match it. Merging to `main` is how things get deployed. CI never touches
a cluster; its only write is a bot commit here that bumps an image tag.

```
development (automatic)
tloi-dalat/TLOJ, judge-server  main ──build──▶  ghcr.io/tloi-dalat/oj-*:main-<sha>
        │ repository_dispatch "sync-version"
        ▼
control-plane  ── bot commit: clusters/development/online-judge/<app>/values.yaml image.tag ──▶  ArgoCD (dev cluster) syncs

production (a reviewed PR)
TLOJ, judge-server  merge main → release        ──▶ tag X.(Y+1).0 ──build──▶  ghcr.io/tloi-dalat/oj-*:X.Y.Z
                    push to releases/<anything> ──▶ tag X.Y.(Z+1) ──build──▶  (never overwritten)
control-plane  ── your PR: clusters/production/online-judge/<app>/values.yaml image.tag: X.Y.Z ──▶  ArgoCD (prod cluster) syncs
```

## Layout

```
clusters/
  development/                    ← dev VPS: follows `main` automatically
    application-set.yaml          ← one ArgoCD app per directory below (applied once at bootstrap)
    cloudflared/tunnel/           ← the only way in, for every namespace: Cloudflare Tunnel connector (routes + DNS: terraform-cloudflare)
    infisical/                    ← namespace "infisical"
      operator/  Infisical Secrets Operator: Infisical Cloud → Kubernetes Secrets
      auth/      its login (machine identity; the Secret itself is created by bootstrap/infisical-login.sh)
    online-judge/                 ← namespace "online-judge"
      core/      site + bridge + celery: one image, shared values.yaml, migrate PreSync hook
      wsevent/   live-update daemon
      judge/     DMOJ judge (StatefulSet, ptrace sandbox, egress-only NetworkPolicy)
      media/     nginx serving user uploads read-only
      redis/     cache + celery broker
      (MariaDB runs on the VPS host; pods use 10.42.0.1, see core/values.yaml)
      storage/   PVs for media + problem data (existing dirs on the VPS; Retain, never pruned)
      secrets/   which Infisical folders become which Secrets
  production/                     ← production VPS: same layout, release tags (X.Y.Z) only, changed by PR
bootstrap/
  development/README.md           ← runbook: from a bare VPS to a running cluster
  production/README.md            ← what differs for the production cluster
  infisical-login.sh              ← once per cluster: the Infisical login every other secret comes from
  new-app-secrets.sh              ← random app secrets for a NEW environment, to paste into Infisical
```

App names are `<namespace>-<dir>` (e.g. `online-judge-core`), and resources are named after the Helm release
(`online-judge-site`, `online-judge-bridge`, …). Adding a service later, say `quiz`, means adding `clusters/development/quiz/<app>/`. The
ApplicationSet picks it up without any change.

## Common changes

| I want to… | Do this |
|---|---|
| Deploy a new version to **development** | Nothing. Merge to `main` in the app repo; CI commits the tag bump here |
| Cut a **release** | In the app repo, merge `main` → `release`. CI tags the next minor (`1.1.1` → `1.2.0`) and builds `:1.2.0` |
| Cut a **hotfix** | `git switch -c releases/<name> 1.2.0`, commit the fix, push. CI tags `1.2.1` and builds it. Merge the fix back to `main` too |
| Deploy to **production** | PR here setting `image.tag` in `clusters/production/online-judge/<app>/values.yaml`. Copy the block from the tag build's run summary. `core` + `wsevent` move together |
| Roll back | Dev: `git revert` the bot commit. Prod: PR setting `image.tag` back to the previous `X.Y.Z` (or revert the release PR) |
| See what runs where | The app repo's **Deployments** tab (environments `development`, `production`): every image-tag change on `main` here is recorded there at the exact commit. Releases (with images and the values to paste) are on its **Releases** tab |
| Change a setting | Edit `env:` in the app's `values.yaml`. **Non-secret values only**, which CI enforces |
| Change a secret | Edit it in Infisical (project TLOI → environment → folder `/online-judge/core`, or `/online-judge/judge` for the judge key). The Secret updates within a minute and the pods restart themselves. No commit |
| Add a secret | Add it in Infisical. `core/` (site, bridge, celery) gets every key in `/online-judge/core` via `envFrom`; other apps need a `secretKeyRef` to `online-judge-core-env` |
| Change routing / add a hostname | PR to `tloi-dalat/terraform-cloudflare`: `zero-trust/tunnel/tunnels/control-plane-development.yaml` |
| Scale | Dev: `replicaCount` (site only; bridge, wsevent and redis must stay at 1). Production: site autoscales; tune `autoscaling` in `core/site.yaml` (raise `minReplicas` ahead of a big contest) |

Every app uses the shared chart `oci://ghcr.io/tloi-dalat/charts/app`, pinned in each
`kustomization.yaml`. All chart options are in the `tloi-dalat/charts` repo.

## GitHub Deployments and Releases

`deployments.yaml` (merges to `main`) and `repo-dispatch.yaml` (bot commits) call
`control-plane-deployments.yaml`: each changed `image.tag` becomes a Deployment in the repo the image
was built from. "Success" means the change is on `main`; ArgoCD applies it within minutes. One-time:

- Nothing per repo: the workflows use the org's CI GitHub App (org secrets `CI_APP_ID`,
  `CI_APP_PRIVATE_KEY`; see reusable-workflow's README, "One-time setup").
- The Deployment's link comes from the app's own `values.yaml`: `url:` if set (the chart ignores it),
  otherwise `https://<env.SITE__DOMAIN>`. So `online-judge` needs nothing; a new app like `quiz` sets
  `url: https://quiz.tloi.vn` in `clusters/<env>/quiz/<app>/values.yaml` if it has no `SITE__DOMAIN`.

## Values to fill in before first deploy

`grep -rn CHANGEME clusters/` lists them all:

| Where | What |
|---|---|
| `online-judge/storage/{media,problems}.yaml` | the existing media and problem-data directories on the dev VPS |
| `online-judge/{core,media}/values.yaml` | UID/GID owning those directories (`id tloi`) |
| `online-judge/secrets/online-judge*-env.yaml` | the Infisical project slug (Project Settings) |
| `online-judge/{core,wsevent,judge}/values.yaml` | `image.tag`, set by the first CI deploy (dev) / a release tag (prod) |

Production has its own list: `bootstrap/production/README.md`.

## Rules

- **No plaintext secrets**, anywhere. Settings go in `values.yaml`; secrets go in Infisical. The only
  credentials outside it (ArgoCD's repo access, Infisical's own login) are created by hand once per cluster.
  `.gitignore` blocks key and credential files, and the lint workflow rejects secret-looking literals.
- **Volumes are never pruned.** PVs use `Retain` plus `Prune=false,Delete=false`. Removing a directory
  here won't delete data, but double-check any PR that touches `storage/`.
- **Pin versions**: chart versions and image tags, never `latest`.
- **Production runs release tags only** (`X.Y.Z`), never `main-<sha>`. Those tags are immutable: CI
  refuses to rebuild one that exists, so `1.2.0` in production is always the same image.
