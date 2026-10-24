# control-plane

GitOps for TLOI. ArgoCD in each cluster syncs `clusters/<env>/`; merging to `main` deploys.

- **development** follows `main` of each app repo: a bot commits each new image tag here.
- **production** runs release tags (`X.Y.Z`) only, set here by PR.

```
clusters/<env>/
  application-set.yaml   one ArgoCD app per <namespace>/<app> directory
  cloudflared/tunnel/    tunnel connector
  infisical/             secrets operator and its login
  online-judge/          core (site, bridge, celery), wsevent, judge, media, redis, storage, secrets
  database/              mariadb-operator, mariadb
  platform/              sqllab (DbGate), atlantis (production)
bootstrap/               one-time cluster setup files
docs/
  setup.md               set up a new VPS (development or production)
  operations.md          deploy, configure, scale, database, SQL Lab
```

Rules: no secrets in git; pin chart versions and image tags; review any change to `storage/`.
