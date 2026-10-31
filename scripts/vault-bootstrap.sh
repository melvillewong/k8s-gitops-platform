#!/usr/bin/env bash
# Init (first run), unseal (every run), configure Kubernetes auth and seed secrets.
# Idempotent: safe to re-run after any Vault restart (standalone always restarts sealed).
# Re-run safety: it restarts only Vault consumers that cannot recover alone (not injected, or stuck in agent backoff); healthy pods are never touched.
# Homelab tradeoff: 1 unseal key share + root token kept in a gitignored file on this box (prod: Shamir shares split across people, or KMS auto-unseal).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="$ROOT/vault-unseal-keys.json" # gitignored (*-unseal-keys*)
POD=vault-0

vault_exec() { kubectl -n vault exec -i "$POD" -- "$@"; }
# because: argv is visible to every local user (ps); the token goes over stdin as line 1, sh reads it into the env, then execs vault
vault_tok() { kubectl -n vault exec -i "$POD" -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' vault "$@"; }
vault_auth()    { printf '%s\n' "$ROOT_TOKEN" | vault_tok "$@"; }            # no data on stdin
vault_auth_in() { { printf '%s\n' "$ROOT_TOKEN"; cat; } | vault_tok "$@"; }  # caller's stdin follows the token (for `-` values)

# because: on a fresh rebuild ArgoCD creates objects minutes after `up`; kubectl wait fails at once on a missing object
wait_exists() { # <namespace> <kind/name>
  for _ in $(seq 120); do
    kubectl -n "$1" get "$2" > /dev/null 2>&1 && return 0
    sleep 5
  done
  echo "$1/$2 not created within 10 min" >&2; exit 1
}

echo "waiting for $POD to run (it stays NotReady while sealed)"
wait_exists vault pod/"$POD"
kubectl -n vault wait pod/"$POD" --for=jsonpath='{.status.phase}'=Running --timeout=5m

status() { vault_exec vault status -format=json || true; } # exit 2 = sealed, still valid JSON

echo "waiting for Vault to answer (pod Running is not enough: the server may still be starting)"
for _ in $(seq 60); do
  jq -e 'has("initialized")' <<< "$(status)" > /dev/null 2>&1 && break
  sleep 5
done
jq -e 'has("initialized")' <<< "$(status)" > /dev/null 2>&1 \
  || { echo "Vault did not answer within 5 min" >&2; exit 1; }

if [ "$(status | jq -r .initialized)" != "true" ]; then
  # because: status is real JSON here, so Vault is truly empty (fresh PVC) and old keys belong to a destroyed instance;
  # move them aside, never delete or overwrite (gitignored by *-unseal-keys*)
  if [ -s "$KEYS_FILE" ]; then
    BAK="$KEYS_FILE.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$KEYS_FILE" "$BAK"
    echo "fresh Vault: old keys moved to $BAK"
  fi
  echo "initialising Vault (1 key share)"
  # because: `> "$KEYS_FILE"` empties the file before init runs; write to a temp file (mktemp = mode 600), move only on success
  TMP="$(mktemp "$KEYS_FILE.XXXX")"
  vault_exec vault operator init -key-shares=1 -key-threshold=1 -format=json > "$TMP"
  mv "$TMP" "$KEYS_FILE"
fi

[ -s "$KEYS_FILE" ] || { echo "Vault is initialised but $KEYS_FILE is missing; cannot unseal" >&2; exit 1; }
UNSEAL_KEY="$(jq -r '.unseal_keys_b64[0]' "$KEYS_FILE")"
ROOT_TOKEN="$(jq -r .root_token "$KEYS_FILE")"

if [ "$(status | jq -r .sealed)" = "true" ]; then
  # because: sys/unseal needs no token; key=- reads the key from stdin, not argv
  printf '%s' "$UNSEAL_KEY" | vault_exec vault write sys/unseal key=- > /dev/null
  echo "unsealed"
else
  echo "already unsealed"
fi

# Vault CLI success lines ("Success! Data written to ...") go to /dev/null; errors still reach stderr
# KV v2 at secret/
vault_auth secrets list -format=json | jq -e 'has("secret/")' > /dev/null \
  || vault_auth secrets enable -path=secret kv-v2 > /dev/null
echo "kv v2 at secret/ on"

# Kubernetes auth: Vault runs in-cluster, so it uses its own SA token + cluster CA as the TokenReview client
vault_auth auth list -format=json | jq -e 'has("kubernetes/")' > /dev/null \
  || vault_auth auth enable kubernetes > /dev/null
vault_auth write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443" > /dev/null
echo "kubernetes auth on"

# JWT auth for GitHub Actions: Vault verifies the job's OIDC token against GitHub's public keys (no shared secret)
# because: Vault fetches GitHub's OIDC discovery URL here, so this fails with VPN on
vault_auth auth list -format=json | jq -e 'has("jwt/")' > /dev/null \
  || vault_auth auth enable jwt > /dev/null
vault_auth write auth/jwt/config \
  oidc_discovery_url="https://token.actions.githubusercontent.com" \
  bound_issuer="https://token.actions.githubusercontent.com" > /dev/null
echo "jwt auth on"

# Policies as code: apps/vault/policies/<name>.hcl
for f in "$ROOT"/apps/vault/policies/*.hcl; do
  vault_auth_in policy write "$(basename "$f" .hcl)" - < "$f" > /dev/null
done
echo "policies loaded"

# Role: SA loki in ns logging -> policy loki-s3
vault_auth write auth/kubernetes/role/loki \
  bound_service_account_names=loki \
  bound_service_account_namespaces=logging \
  policies=loki-s3 \
  ttl=15m > /dev/null

# Role: SA monitoring-grafana in ns monitoring -> policy grafana
vault_auth write auth/kubernetes/role/grafana \
  bound_service_account_names=monitoring-grafana \
  bound_service_account_namespaces=monitoring \
  policies=grafana \
  ttl=15m > /dev/null

# Role: SA monitoring-kube-prometheus-alertmanager in ns monitoring -> policy alertmanager
vault_auth write auth/kubernetes/role/alertmanager \
  bound_service_account_names=monitoring-kube-prometheus-alertmanager \
  bound_service_account_namespaces=monitoring \
  policies=alertmanager \
  ttl=15m > /dev/null

# Role ci: only this repo's main branch -> policy ci; token lives about one job (default would be 768h)
# because: repository_id never changes, so a new repo reusing this name after a rename or delete cannot match
# because: token_max_ttl stops renewals stretching the token to the 768h system max
vault_auth_in write auth/jwt/role/ci - > /dev/null <<'EOF'
{
  "role_type": "jwt",
  "user_claim": "repository",
  "bound_audiences": ["vault-k8s-gitops-platform"],
  "bound_claims": {
    "repository_id": "1433945542",
    "ref": "refs/heads/main"
  },
  "token_policies": ["ci"],
  "token_ttl": "5m",
  "token_max_ttl": "10m"
}
EOF
echo "roles written (loki, grafana, alertmanager, ci)"

# Seed: Garage S3 key for Loki, read from Garage (source of truth until the init Job writes it here)
echo "waiting for the garage-init Job (it creates loki-key)"
wait_exists storage job/garage-init
kubectl -n storage wait job/garage-init --for=condition=complete --timeout=15m > /dev/null
GARAGE_KEY="$(kubectl -n storage exec garage-0 -- /garage key info loki-key --show-secret)"
KEY_ID="$(awk -F': *' '/^Key ID/ {print $2}' <<< "$GARAGE_KEY")"
KEY_SECRET="$(awk -F': *' '/^Secret key/ {print $2}' <<< "$GARAGE_KEY")"
[ -n "$KEY_ID" ] && [ -n "$KEY_SECRET" ] || { echo "could not parse Garage key info output" >&2; exit 1; }
# secret via stdin (secret_access_key=-), so it never appears in a process list; printf adds no trailing newline
printf '%s' "$KEY_SECRET" | vault_auth_in kv put secret/garage/loki-key access_key_id="$KEY_ID" secret_access_key=- > /dev/null
echo "secret/garage/loki-key seeded"

# Seed: Discord webhook from the gitignored .env (kept outside Git, like the unseal keys file); shared by CI and Alertmanager
if [ -f "$ROOT/.env" ] && grep -q '^DISCORD_WEBHOOK_URL=' "$ROOT/.env"; then
  WEBHOOK_URL="$(grep '^DISCORD_WEBHOOK_URL=' "$ROOT/.env" | cut -d= -f2-)"
  printf '%s' "$WEBHOOK_URL" | vault_auth_in kv put secret/notify/discord webhook_url=- > /dev/null
  echo "secret/notify/discord seeded"
else
  echo "skip: no DISCORD_WEBHOOK_URL in .env, secret/notify/discord not seeded" >&2
fi

if ! vault_auth kv get secret/grafana/admin > /dev/null 2>&1; then
  # password via stdin (password=-), so it never appears in a process list
  openssl rand -base64 24 | tr -d '\n' | vault_auth_in kv put secret/grafana/admin password=- > /dev/null
  echo "secret/grafana/admin seeded"
else
  echo "secret/grafana/admin already exists"
fi

# Restart Vault consumers (label vault-inject=true, the injector's objectSelector) that cannot recover alone; their controller recreates them:
# - no vault-agent-init: pod was created before the injector webhook existed (cross-app race on a fresh rebuild), so it never gets the secret
# - vault-agent-init still running: it failed while Vault was sealed and waits out its retry backoff (up to ~5 min); a new pod logs in at once
kubectl get pods -A -l vault-inject=true -o json \
  | jq -r '.items[]
      | (any(.spec.initContainers[]?; .name == "vault-agent-init") | not) as $missed
      | (any(.status.initContainerStatuses[]?; .name == "vault-agent-init" and .state.running)) as $waiting
      | select($missed or $waiting)
      | "\(.metadata.namespace) \(.metadata.name) \(if $missed then "not injected" else "agent backoff" end)"' \
  | while read -r ns pod why; do
      kubectl -n "$ns" delete pod "$pod" --wait=false > /dev/null
      echo "restarted $ns/$pod ($why)"
    done

echo "done: Vault unsealed, configured and seeded"
