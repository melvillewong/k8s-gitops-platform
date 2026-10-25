# ADR-0004: Platform secrets from HashiCorp Vault (standalone, Kubernetes auth, agent injector)

- Status: accepted
- Date: 23-Oct-26 (decided 18-Sep-26; standalone mode 04-Oct-26)

## Context

Three workloads need credentials at runtime: Loki (Garage S3 key), Grafana (admin password) and Alertmanager (Discord webhook URL). The repo is the source of truth for everything else, so the question is where secret values live and how a pod gets them without the value ever sitting in Git, a k8s manifest, CI settings or a process list. A dummy secret would make "runtime secret injection" hollow; the consumers must be real.

## Decision

**HashiCorp Vault in standalone mode, read by pods through Kubernetes auth and the Vault agent injector.**

- Vault: ArgoCD app (`apps/vault`, chart `hashicorp/vault`), standalone mode, file storage on a 1Gi PVC, KV v2 at `secret/`.
- Identity: Kubernetes auth. A pod logs in with its ServiceAccount token; Vault checks it with the API server (TokenReview).
- Delivery: the agent injector adds a `vault-agent-init` init container (`agent-pre-populate-only`) that renders the secret to a file under `/vault/secrets/`. The app reads the file; no k8s Secret is created.
- Init, unseal, auth config, roles, policies and seeding: `scripts/vault-bootstrap.sh` (`mise run vault`), idempotent.

## Consumers and least privilege

| Consumer | Vault path | Rendered as |
|---|---|---|
| Loki | `secret/garage/loki-key` | AWS shared credentials file (`AWS_SHARED_CREDENTIALS_FILE`) |
| Grafana | `secret/grafana/admin` | password file, read via `$__file{}` |
| Alertmanager | `secret/notify/discord` | `webhook_url_file` |

- One role per consumer, bound to ServiceAccount + namespace; one policy per consumer, `read` on its own path only (`apps/vault/policies/*.hcl`). Policies are default deny, so blast radius grows only by over-granting.
- Dedicated ServiceAccounts, never `default`: binding a role to `default` would hand the secret to every pod in the namespace.
- Injection is opt-in: the webhook's `objectSelector` matches only pods labelled `vault-inject: "true"`, so a down injector blocks only those pods.
- `failurePolicy: Fail`: a consumer is rejected and retried rather than started without its secret.

## Rejected

- **Plain k8s Secrets / SOPS / Sealed Secrets**: the value (encrypted or not) lives in Git or etcd as a long-lived object; no per-workload identity, no central audit point.
- **Vault dev mode**: in-memory and auto-unsealed, so every restart loses all secrets; init/seal/unseal is never exercised.
- **External Secrets Operator / Vault Secrets Operator**: one more controller, and it syncs into k8s Secrets anyway; the injector keeps the value out of etcd. Fits once there are many consumers.
- **Secrets as env vars**: visible in `kubectl describe`, inherited by child processes; files are scoped to the pod.

## Consequences

- **Manual unseal**: standalone always restarts sealed. 1 unseal share + root token in a gitignored file on the box, read by the script. Prod: Shamir shares split across people, or KMS auto-unseal, and the root token revoked after setup. This is the 1 manual step in the rebuild.
- **Not hardened**: no TLS, no audit device, no HA (Raft), no snapshot backup. Accepted: homelab scale, every secret is re-seedable (Garage key re-read from Garage, webhook from `.env`, Grafana password regenerated).
- **Webhook race on a fresh rebuild**: a consumer pod created before the injector's webhook exists is never injected; one that failed while Vault was sealed waits out the agent's retry backoff (up to ~5 min). `mise run vault` ends by restarting only those pods (see ADR-0003, `docs/troubleshooting.md`).
- **Pre-populate only**: secrets render once at pod start; a rotated value needs a pod restart.
- **Bearer tokens**: a stolen ServiceAccount JWT is not detected by TokenReview; mitigated by short-lived projected tokens and a 15 min role TTL.

## Related

ADR-0003 (Vault is a GitOps workload; consumers retry instead of sync waves). ADR-0005 (CI reads Vault through JWT auth). `docs/runbooks/rebuild.md`.
