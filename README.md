# Kubernetes GitOps Platform

A self-hosted Kubernetes platform that rebuilds from nothing in under 8 minutes with one manual step.

- **GitOps**: Terraform seeds a k3d cluster and ArgoCD; ArgoCD delivers every other workload from this repo.
- **No static credentials**: secrets come from HashiCorp Vault; CI runs on in-cluster runners that log in to Vault with GitHub OIDC.
- **Alerting**: Prometheus, Grafana and Loki turn failures into a Discord alert with a runbook link.

Built as a portfolio project on a single Linux box. Every tool is here because of a problem it solves; the reasoning is in the [ADRs](docs/adr/).

## Results

| Claim | Number | How it was measured |
|---|---|---|
| Rebuild from zero | 7 min 43 s, 1 manual step | DR drill: `mise run down`, then `mise run up` to all 9 apps Synced/Healthy, cold image pulls |
| Services delivered by GitOps | 8 | `argocd app list`, root excluded; 0 manual `kubectl apply` |
| Drift revert | under 2 s | `kubectl scale` a managed Deployment to 0; events show the revert and a new pod within 1-2 s |
| Static credentials removed | 3 | Loki's S3 key, Grafana admin password, Discord webhook served from Vault; 0 GitHub repo secrets |
| Time-to-alert | 3 min 33 s | Garage scaled to 0 via Git; pod gone to Discord message (`for: 2m` + `group_wait` 30 s) |

The DR drill also found and fixed two start-up races (a crashed k3s agent, a pod created before the Vault injector's webhook) and a false `GarageDown` alert on every rebuild; see [docs/troubleshooting.md](docs/troubleshooting.md).

## Architecture

```mermaid
flowchart TB
  dev([git push / PR]) --> GH[(GitHub repo)]
  GH -- "1. PR checks" --> ARC
  subgraph TF["Terraform seed (mise run up)"]
    K3D[k3d cluster<br/>1 server + 3 agents]
    ACD[ArgoCD + root app]
  end
  K3D --> ACD
  GH -- "2. ArgoCD pulls apps/*" --> ACD
  subgraph CLUSTER["Delivered by ArgoCD (app-of-apps)"]
    VAULT[Vault<br/>KV + k8s / JWT auth]
    GARAGE[(Garage S3)]
    LOKI[Loki]
    ALLOY[Alloy DaemonSet]
    PROM[Prometheus]
    AM[Alertmanager]
    GRAF[Grafana]
    ARC[ARC runners]
  end
  ACD --> CLUSTER
  VAULT -. "3. S3 key" .-> LOKI
  VAULT -. "3. admin password" .-> GRAF
  VAULT -. "3. webhook URL" .-> AM
  ARC -. "4. OIDC login" .-> VAULT
  ALLOY -- "5. pod logs" --> LOKI
  LOKI -- chunks --> GARAGE
  PROM -- "6. scrape" --> GARAGE
  PROM --> AM
  AM -- "7. alert + runbook" --> DISCORD([Discord])
  GRAF --> PROM
  GRAF --> LOKI
```

1. **PR checks**: validation plus Trivy on in-cluster runners; merge = deploy, so the PR is the gate ([ADR-0007](docs/adr/0007-trivy-pr-scanning.md)).
2. **GitOps**: Terraform installs only the cluster and ArgoCD; ArgoCD syncs everything else, with self-heal ([ADR-0003](docs/adr/0003-tf-argocd-delivery-boundary.md)).
3. **Secrets**: pods log in to Vault with their ServiceAccount and get the secret as a file; no k8s Secret ([ADR-0004](docs/adr/0004-vault-secrets.md)).
4. **Keyless CI**: Vault accepts the job's OIDC token only for this repo and `main`, for 5 minutes ([ADR-0005](docs/adr/0005-ci-arc-runners-vault-jwt.md)).
5. **Logs**: Alloy ships pod logs to Loki, which stores them in Garage ([ADR-0002](docs/adr/0002-object-store-garage-no-native-locking.md)).
6. **Metrics**: scrape targets and alert rules live in Git next to each workload.
7. **Alerting**: critical alerts reach Discord with a runbook link ([ADR-0006](docs/adr/0006-observability-stack.md)).

## Stack

| Tool | Because |
|---|---|
| Terraform | the cluster and ArgoCD must exist before GitOps can start; TF owns only that seed |
| k3d | a multi-node Kubernetes cluster on one box (nodes are containers), created and destroyed by one command |
| ArgoCD | continuous reconcile from Git: audit trail, revert by commit, drift self-heal |
| HashiCorp Vault | one place for secrets, read by workload identity, never stored in Git or CI |
| GitHub Actions + ARC | CI needs to reach Vault, which is never exposed; runners live in the cluster |
| Trivy | merge = deploy, so an unsafe manifest must be caught at the PR, not in the cluster |
| Prometheus + Alertmanager | metrics and alert rules as code, routed to a person |
| Grafana | one UI for metrics and logs, dashboards and datasources as code |
| Loki + Alloy | logs indexed by labels only, cheap to run, same labels as metrics |
| Garage | S3-compatible store for Loki on the same box (MinIO community edition is archived) |
| Forgejo | sample stateful app (Deployment, 5Gi PVC, Ingress at `forgejo.localhost:8080`) proving GitOps delivery of a workload with data |
| mise | pins tool versions and wraps the lifecycle in `up` / `vault` / `down` |

## Quick start

Prerequisites:

- Docker and [mise](https://mise.jdx.dev)
- `.env` copied from `.env.example` (`ARC_APP_ID`, `ARC_INSTALLATION_ID`, `DISCORD_WEBHOOK_URL`; `GITHUB_PAT` only for a private fork)
- `arc-github-app.pem` at the repo root

```bash
mise run up      # k3d cluster -> ArgoCD -> bootstrap Secrets -> all nodes Ready
mise run vault   # the one manual step: init/unseal Vault, configure auth, seed secrets
kubectl -n argocd get applications   # all Synced / Healthy
```

Full steps, backups and failure fixes: [docs/runbooks/rebuild.md](docs/runbooks/rebuild.md).

## What I would do differently

Each line: gap, then the production fix. Accepted here because this is a single-operator homelab.

- **Unseal key and root token in one file on the box** → Shamir shares held by different people, or KMS auto-unseal; root token revoked after setup.
- **Vault without TLS, audit log, HA or backups** → TLS, an audit device, Raft HA and scheduled snapshots off the box.
- **All apps in ArgoCD's `default` project; `main` requires PR checks and signed commits but no reviewer** → one AppProject per app (allowed namespaces and kinds), a required review from a second person.
- **NetworkPolicy only on Garage** → default-deny per namespace with explicit allows, including CI runner egress.
- **Nothing alerts if the monitoring itself dies** → route the always-firing `Watchdog` to a dead-man's switch; meta-alerts on Loki and Alloy.

<details>
<summary>Five more gaps</summary>

- **ARC App key (and the repo PAT, for a private repo) in plaintext `.env`** (needed before Vault exists) → an external secret store with a cloud KMS.
- **Garage with one replica on the same disk** → 3 nodes across failure domains plus an offsite copy.
- **Terraform state local, no locking** → a remote backend with locking.
- **No TLS on ingress** → cert-manager with an internal CA.
- **Negative CI tests deferred** (wrong repo, branch or audience must be refused) → prove them with failing runs; one source for chart versions (e.g. Renovate).

</details>
