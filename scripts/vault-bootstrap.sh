#!/usr/bin/env bash
# Init (first run), unseal (every run), configure Kubernetes auth and seed secrets.
# Idempotent: safe to re-run after any Vault restart (standalone always restarts sealed).
# Homelab tradeoff: 1 unseal key share + root token kept in a gitignored file on this box (prod: Shamir shares split across people, or KMS auto-unseal).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="$ROOT/vault-unseal-keys.json" # gitignored (*-unseal-keys*)
POD=vault-0

vault_exec() { kubectl -n vault exec -i "$POD" -- "$@"; }
vault_auth() { vault_exec env VAULT_TOKEN="$ROOT_TOKEN" vault "$@"; }

echo "waiting for $POD to run (it stays NotReady while sealed)"
kubectl -n vault wait pod/"$POD" --for=jsonpath='{.status.phase}'=Running --timeout=5m

status() { vault_exec vault status -format=json || true; } # exit 2 = sealed, still valid JSON

if [ "$(status | jq -r .initialized)" != "true" ]; then
  echo "initialising Vault (1 key share)"
  vault_exec vault operator init -key-shares=1 -key-threshold=1 -format=json > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
fi

[ -s "$KEYS_FILE" ] || { echo "Vault is initialised but $KEYS_FILE is missing; cannot unseal" >&2; exit 1; }
UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")"
ROOT_TOKEN="$(jq -r .root_token "$KEYS_FILE")"

if [ "$(status | jq -r .sealed)" = "true" ]; then
  echo "unsealing"
  vault_exec vault operator unseal "$UNSEAL_KEY" > /dev/null
fi

# KV v2 at secret/
vault_auth secrets list -format=json | jq -e 'has("secret/")' > /dev/null \
  || vault_auth secrets enable -path=secret kv-v2

# Kubernetes auth: Vault runs in-cluster, so it uses its own SA token + cluster CA as the TokenReview client
vault_auth auth list -format=json | jq -e 'has("kubernetes/")' > /dev/null \
  || vault_auth auth enable kubernetes
vault_auth write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

# Policies as code: apps/vault/policies/<name>.hcl
for f in "$ROOT"/apps/vault/policies/*.hcl; do
  vault_auth policy write "$(basename "$f" .hcl)" - < "$f"
done

# Role: SA demo in ns vault-demo -> policy loki-s3 (Loki gets its own role in task-07)
vault_auth write auth/kubernetes/role/demo \
  bound_service_account_names=demo \
  bound_service_account_namespaces=vault-demo \
  policies=loki-s3 \
  ttl=15m

# Seed: Garage S3 key for Loki, read from Garage (source of truth until the init Job writes it here)
GARAGE_KEY="$(kubectl -n storage exec garage-0 -- /garage key info loki-key --show-secret)"
KEY_ID="$(awk -F': *' '/^Key ID/ {print $2}' <<< "$GARAGE_KEY")"
KEY_SECRET="$(awk -F': *' '/^Secret key/ {print $2}' <<< "$GARAGE_KEY")"
[ -n "$KEY_ID" ] && [ -n "$KEY_SECRET" ] || { echo "could not parse Garage key info output" >&2; exit 1; }
vault_auth kv put secret/garage/loki-key access_key_id="$KEY_ID" secret_access_key="$KEY_SECRET" > /dev/null

echo "Vault ready: unsealed, kubernetes auth on, secret/garage/loki-key seeded"
