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

# JWT auth for GitHub Actions: Vault verifies the job's OIDC token against GitHub's public keys (no shared secret)
vault_auth auth list -format=json | jq -e 'has("jwt/")' > /dev/null \
  || vault_auth auth enable jwt
vault_auth write auth/jwt/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com"

echo "kubernetes + jwt auth on"

# Policies as code: apps/vault/policies/<name>.hcl
for f in "$ROOT"/apps/vault/policies/*.hcl; do
  vault_auth policy write "$(basename "$f" .hcl)" - < "$f"
done

echo "policies loaded successfully"

# Role: SA demo in ns vault-demo -> policy loki-s3 (Loki gets its own role in task-07)
vault_auth write auth/kubernetes/role/demo \
  bound_service_account_names=demo \
  bound_service_account_namespaces=vault-demo \
  policies=loki-s3 \
  ttl=15m

# Role: SA monitoring-grafana in ns monitoring -> policy grafana
vault_auth write auth/kubernetes/role/grafana \
  bound_service_account_names=monitoring-grafana \
  bound_service_account_namespaces=monitoring \
  policies=grafana \
  ttl=15m

# Role ci: only this repo's main branch -> policy ci; token lives about one job (default would be 768h)
vault_auth write auth/jwt/role/ci - <<'EOF'
{
  "role_type": "jwt",
  "user_claim": "repository",
  "bound_audiences": ["vault-k8s-devops-platform"],
  "bound_claims": {
    "repository": "melvillewong/k8s-devops-platform",
    "ref": "refs/heads/main"
  },
  "token_policies": ["ci"],
  "token_ttl": "5m"
}
EOF

# Seed: Garage S3 key for Loki, read from Garage (source of truth until the init Job writes it here)
GARAGE_KEY="$(kubectl -n storage exec garage-0 -- /garage key info loki-key --show-secret)"
KEY_ID="$(awk -F': *' '/^Key ID/ {print $2}' <<< "$GARAGE_KEY")"
KEY_SECRET="$(awk -F': *' '/^Secret key/ {print $2}' <<< "$GARAGE_KEY")"
[ -n "$KEY_ID" ] && [ -n "$KEY_SECRET" ] || { echo "could not parse Garage key info output" >&2; exit 1; }
vault_auth kv put secret/garage/loki-key access_key_id="$KEY_ID" secret_access_key="$KEY_SECRET" > /dev/null
echo "secret/garage/loki-key seeded"

# Seed: Discord webhook from the gitignored .env (kept outside Git, like the unseal keys file); shared by CI now, Alertmanager in task-06
if [ -f "$ROOT/.env" ] && grep -q '^DISCORD_WEBHOOK_URL=' "$ROOT/.env"; then
  WEBHOOK_URL="$(grep '^DISCORD_WEBHOOK_URL=' "$ROOT/.env" | cut -d= -f2-)"
  vault_auth kv put secret/notify/discord webhook_url="$WEBHOOK_URL" > /dev/null
  echo "secret/notify/discord seeded"
else
  echo "skip: no DISCORD_WEBHOOK_URL in .env, secret/notify/discord not seeded" >&2
fi

if ! vault_auth kv get secret/grafana/admin > /dev/null 2>&1; then
  # password via stdin (password=-), so it never appears in a process list
  openssl rand -base64 24 | tr -d '\n' | vault_auth kv put secret/grafana/admin password=- > /dev/null
  echo "secret/grafana/admin seeded"
else
  echo "secret/grafana/admin already exists"
fi

echo "Vault ready: unsealed"
