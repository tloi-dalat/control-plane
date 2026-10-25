# control-plane

GitOps for TLOI. ArgoCD in each cluster syncs `clusters/<env>/`; merging to `main` deploys.

- **development** follows `main` of each app repo: a bot commits each new image tag here.
- **production** runs release tags (`X.Y.Z`) only, set here by PR.
