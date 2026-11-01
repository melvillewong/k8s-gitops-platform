# ADR-0005: CI on in-cluster ARC runners with Vault JWT (OIDC) auth

- Status: accepted
- Date: 23-Oct-26 (decided 18-Sep-26)

## Context

CI has two jobs: validate every PR before merge (in GitOps, merge = deploy, so the PR is the only gate), and read secrets after merge without storing any credential in GitHub. Vault runs inside a k3d cluster on a LAN box and is never exposed to the internet. GitHub-hosted runners cannot reach it.

## Decision

**GitHub Actions jobs run on ephemeral in-cluster runners (Actions Runner Controller, ARC) and log in to Vault with the job's GitHub OIDC token (Vault JWT auth).**

- ARC: two ArgoCD apps, controller (`arc-controller`) and a repo-level runner scale set (`arc-runners`, `runs-on: arc-runner-set`). `minRunners: 0`, `maxRunners: 2`: one pod per job, deleted after. Runner pods run non-root, no privilege escalation, all capabilities dropped. Runners connect outbound to GitHub; nothing inbound.
- Vault JWT auth: Vault verifies the job's OIDC token against GitHub's published keys (`oidc_discovery_url`), so no shared secret exists. Role `ci` binds:
  - `bound_audiences: vault-k8s-gitops-platform` (a token requested for another service is refused),
  - `bound_claims`: this repository's numeric `repository_id` (survives a rename; a new repo reusing the name cannot match) and `refs/heads/main` only,
  - policy `ci`: `read` on `secret/data/notify/discord` only,
  - `token_ttl: 5m` (about one job; default would be 768h), `token_max_ttl: 10m` (renewals cannot stretch it).
- The job reaches Vault at its in-cluster Service (`http://vault.vault.svc:8200`).

## Rejected

- **GitHub-hosted runners + a tunnel to Vault**: exposes the secrets store to the internet to serve a demo; the opposite of what the project shows.
- **GitHub repository secrets**: static, long-lived, copied into GitHub; rotation is manual and a leak is valid until someone notices. Result here: 0 repo secrets.
- **Vault Kubernetes auth for CI**: the runner pod's ServiceAccount token names the pod, not the job; any workflow on the runner would get the same identity. The OIDC token carries repo, ref and workflow, so the role binds on what ran, not where.
- **Always-on runner VM or pod**: idle cost, and state leaks between jobs; ephemeral pods start clean.

## Consequences

- **CI runs inside the cluster**: a malicious job executes next to the platform. Mitigated: repo-level runners (only this repo's jobs land here), fork PRs from any outside contributor wait for maintainer approval before running (public repo), non-root pods, and the PR workflow has `contents: read` and no `id-token`, so PR code cannot log in to Vault (only `main` can, via `notify-merge`). Not covered: no NetworkPolicy on runner egress; a separate cluster or namespace isolation for runners would be the prod answer.
- **Runner image pinned** (`actions-runner:2.338.2`): every rebuild gets the same runner. Must be bumped within 30 days of a new runner release, or GitHub stops sending jobs.
- **No negative login tests**: skipped (01-Nov-26). The role was reviewed instead and hardened: `repository_id` binding and `token_max_ttl`.
- **ARC GitHub App key outside Vault**: ARC needs it before Vault exists; kept in gitignored `.env` + `.pem`, loaded by `scripts/bootstrap-secrets.sh` (ADR-0004).
- **Runner pods share box RAM** with the platform; `maxRunners: 2` caps it.

## Related

ADR-0004 (Vault). `.github/workflows/pr-validate.yml`, `.github/workflows/notify-merge.yml`, `apps/arc/values.yml`.
