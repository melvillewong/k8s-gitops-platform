#!/usr/bin/env bash
# Create the Secrets that need values from outside Git: ARC GitHub App, and repo PAT (ArgoCD, private repo only).
# Source: gitignored .env + arc-github-app.pem. Idempotent: create-or-update via apply.
# because: server-side apply tracks ownership in managedFields; client-side apply would copy the Secret data into an annotation
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/.env"
PEM="$ROOT/arc-github-app.pem"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }
get() { grep "^$1=" "$ENV_FILE" | cut -d= -f2- || true; }
for v in ARC_APP_ID ARC_INSTALLATION_ID; do
  [ -n "$(get "$v")" ] || { echo "missing $v in $ENV_FILE" >&2; exit 1; }
done
[ -f "$PEM" ] || { echo "missing $PEM" >&2; exit 1; }

# because: only a private repo needs credentials; a public repo clones anonymously
if [ -n "$(get GITHUB_PAT)" ]; then
  # because: --from-file with printf keeps the PAT out of process args (ps) and adds no trailing newline
  kubectl -n argocd create secret generic repo-k8s-gitops-platform \
    --from-literal=type=git \
    --from-literal=url=https://github.com/melvillewong/k8s-gitops-platform.git \
    --from-literal=username=melvillewong \
    --from-file=password=<(printf '%s' "$(get GITHUB_PAT)") \
    --dry-run=client -o yaml \
    | kubectl label --local -f - -o yaml argocd.argoproj.io/secret-type=repository \
    | kubectl apply --server-side --field-manager=bootstrap-secrets -f - > /dev/null
  echo "repo-k8s-gitops-platform applied"

  # because: root failed its first Git fetch before the PAT existed; refresh now instead of waiting for the ~3 min poll
  kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 \
    || echo "skip: root Application not found, no refresh" >&2
else
  echo "skip: no GITHUB_PAT, a public repo needs no credentials"
fi

kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f - > /dev/null
kubectl -n arc-runners create secret generic arc-github-app \
  --from-literal=github_app_id="$(get ARC_APP_ID)" \
  --from-literal=github_app_installation_id="$(get ARC_INSTALLATION_ID)" \
  --from-file=github_app_private_key="$PEM" \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=bootstrap-secrets -f - > /dev/null
echo "arc-github-app applied"
