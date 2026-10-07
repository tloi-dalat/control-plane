#!/usr/bin/env bash
# Seal the two credentials that can't live in Infisical. Everything else (DB
# password, Django key, judge key, …) is typed in the Infisical web UI and
# synced by the operator — see clusters/<env>/online-judge/secrets/.
#
#   bootstrap/seal-secrets.sh <env> infisical                 # machine identity login (prompted)
#   bootstrap/seal-secrets.sh <env> cloudflared <UUID>.json   # Cloudflare Tunnel credentials
#
#   <env> is a directory under clusters/: development, production.
#
# Plaintext never touches disk and never appears in a process list: values are
# prompted for or read from the given file, piped to kubectl, and only
# kubeseal's encrypted output is written into clusters/<env>/.
#
# Needs: kubectl (pointing at the cluster) and kubeseal — or set
# SEALED_SECRETS_CERT to the controller's public cert (kubeseal --fetch-cert)
# to seal offline.
set -euo pipefail

usage() { sed -n '6,7p' "$0" | sed 's/^# *//' >&2; exit 1; }
ENVIRONMENT=${1:-}; WHAT=${2:-}
[[ -n "$ENVIRONMENT" && -n "$WHAT" ]] || usage

cd "$(dirname "$0")/.."
[[ -d "clusters/${ENVIRONMENT}" ]] || { echo "no such environment: clusters/${ENVIRONMENT}" >&2; exit 1; }
for bin in kubectl kubeseal; do
  command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }
done

kubeseal_args=(--format yaml --scope strict)
if [[ -n "${SEALED_SECRETS_CERT:-}" ]]; then
  kubeseal_args+=(--cert "$SEALED_SECRETS_CERT")
else
  kubeseal_args+=(--controller-namespace kube-system --controller-name sealed-secrets-controller)
fi

ask() { local v; read -r -s -p "$1: " v; echo >&2; printf '%s' "$v"; }

case "$WHAT" in
  infisical)
    # Infisical → Organization → Access Control → Identities → <identity> →
    # Universal Auth: the Client ID, and a Client Secret created there.
    out="clusters/${ENVIRONMENT}/infisical/auth/infisical-universal-auth.yaml"
    client_id=$(ask "Infisical machine identity Client ID")
    client_secret=$(ask "Infisical machine identity Client Secret")
    [[ -n "$client_id" && -n "$client_secret" ]] || { echo "both are required" >&2; exit 1; }
    printf 'clientId=%s\nclientSecret=%s\n' "$client_id" "$client_secret" \
      | kubectl create secret generic infisical-universal-auth -n infisical \
          --dry-run=client -o yaml --from-env-file=/dev/stdin \
      | kubeseal "${kubeseal_args[@]}" > "$out"
    ;;
  cloudflared)
    # From `cloudflared tunnel create <name>`: ~/.cloudflared/<UUID>.json
    creds=${3:?usage: seal-secrets.sh <env> cloudflared <UUID>.json}
    out="clusters/${ENVIRONMENT}/online-judge/secrets/cloudflared-credentials.yaml"
    kubectl create secret generic cloudflared-credentials -n online-judge \
        --dry-run=client -o yaml --from-file=credentials.json="$creds" \
      | kubeseal "${kubeseal_args[@]}" > "$out"
    ;;
  *) usage ;;
esac

echo "wrote ${out} (encrypted, safe to commit)" >&2
