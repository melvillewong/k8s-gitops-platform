# Rebuild from zero

Full rebuild: `mise run down` then `mise run up`. One step stays manual (`mise run vault`). Values from outside Git live in gitignored files on the box; this file names where each value lives, never the value itself.

## Before destroy: back up

The cluster may hold the only live copy of some values. Pull them into `.env` (and the password manager) first.

```bash
# Repo PAT, private repo only (GitHub shows it only once)
kubectl -n argocd get secret repo-k8s-gitops-platform -o jsonpath='{.data.password}' | base64 -d; echo

# ARC GitHub App IDs
kubectl -n arc-runners get secret arc-github-app -o jsonpath='{.data.github_app_id}' | base64 -d; echo
kubectl -n arc-runners get secret arc-github-app -o jsonpath='{.data.github_app_installation_id}' | base64 -d; echo
```

- Copy `./arc-github-app.pem` off the box too (password manager): it is the only copy.
- Push every commit: ArgoCD builds from GitHub, not the working copy.

## Prerequisites

| Item | Source | On the box |
|---|---|---|
| Repo PAT, private repo only (fine-grained, this repo only, Contents read-only) | GitHub > Settings > Developer settings > Fine-grained tokens (check expiry) | `.env` `GITHUB_PAT=` |
| ARC App ID, Installation ID | the App's settings page / install URL | `.env` `ARC_APP_ID=`, `ARC_INSTALLATION_ID=` |
| ARC App private key | password manager | `./arc-github-app.pem` |
| Discord webhook URL | password manager | `.env` `DISCORD_WEBHOOK_URL=` |

- `.env` and `*.pem` are gitignored; keep both `chmod 600`.
- VPN off: `ip route get 1.1.1.1` must not show your VPN interface (e.g. `tun0`).
- Run every command from the repo root (mise sets `KUBECONFIG`).

## Rebuild

```bash
mise run down                     # destroy platform, then cluster
rm vault-unseal-keys.json         # old Vault is gone with its PVC; the key unlocks nothing now
mise run up                       # cluster -> ArgoCD -> Secrets from .env -> all nodes Ready
```

If `up` fails at the last step (`timed out waiting for the condition on nodes/...`): a k3s agent crashed at start. `docker restart k3d-mycluster-<node>`, then `kubectl get nodes` until all `Ready` (see `docs/troubleshooting.md`).

Automatic, no action:

- Repo PAT + ARC App Secrets: `scripts/bootstrap-secrets.sh` at the end of `up` (re-run alone: `mise run secrets`).
- `garage-rpc`: PreSync Job `garage-rpc-init` in `apps/garage`.
- Garage layout, bucket, key: PostSync Job `garage-init`.

### Manual: Vault init, unseal, seed

Run straight after `up`: the script waits until `vault-0` exists, and waits for the `garage-init` Job before copying `loki-key` from Garage into Vault.

```bash
mise run vault
```

- Fresh Vault: the script inits it and writes a new `./vault-unseal-keys.json`. Back it up off the box.
- At the end it deletes pods still stuck in `vault-agent-init`, so they log in at once instead of waiting out the agent's retry backoff (up to ~5 min).
- Grafana admin password is new (generated on seed). Token over stdin, not argv:

  ```bash
  jq -r .root_token vault-unseal-keys.json | kubectl -n vault exec -i vault-0 -- \
    sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault kv get -field=password secret/grafana/admin'
  ```

## Done when

```bash
kubectl -n argocd get applications    # every app Synced / Healthy
```
