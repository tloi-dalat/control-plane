#!/usr/bin/env bash
set -euo pipefail

ENVIRONMENT=${1:?usage: infisical-login.sh <env>   (development | production)}
command -v kubectl >/dev/null || { echo "missing: kubectl" >&2; exit 1; }

context=$(kubectl config current-context)
echo "kubectl context: ${context}"
read -r -p "Create the Infisical login for '${ENVIRONMENT}' in this cluster? [y/N] " ok
[[ "$ok" == [yY] ]] || { echo "aborted" >&2; exit 1; }

echo "Infisical → Organization → Access Control → Identities → tloi-${ENVIRONMENT} → Universal Auth"
read -r -p "Client ID: " client_id
read -r -s -p "Client Secret: " client_secret; echo
[[ -n "$client_id" && -n "$client_secret" ]] || { echo "both are required" >&2; exit 1; }

if command -v curl >/dev/null; then
  if ! printf 'clientId=%s&clientSecret=%s' "$client_id" "$client_secret" \
      | curl -fsS -o /dev/null https://app.infisical.com/api/v1/auth/universal-auth/login --data @-; then
    echo "Infisical rejected these credentials (wrong ID/secret, or the region is not app.infisical.com)" >&2
    exit 1
  fi
  echo "Infisical accepted the credentials."
fi

kubectl create namespace infisical --dry-run=client -o yaml | kubectl apply -f - >/dev/null
printf 'clientId=%s\nclientSecret=%s\n' "$client_id" "$client_secret" \
  | kubectl create secret generic infisical-bootstrap -n infisical \
      --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -

cat <<MSG

Done. The operator picks it up within a minute:
  kubectl -n infisical get infisicalauth
  kubectl get infisicalstaticsecrets -A
MSG
