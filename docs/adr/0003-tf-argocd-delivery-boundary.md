# ADR-0003: Terraform-vs-ArgoCD delivery boundary (thin TF seed, fat GitOps)

- Status: accepted
- Date: 02-Jul-26

## Context

Two tools can create in-cluster resources: Terraform (`helm`/`kubernetes`
providers in `infra/platform`) and ArgoCD (`Application`s reconciling `apps/`).
Without an explicit line, both drift toward doing everything, and workloads
(Garage, Loki, Vault, observability, Forgejo) could land in either. ADR-0001
already stated "TF owns up to and including ArgoCD; ArgoCD owns `apps/`" but
left the workload set ambiguous.

## Decision

**Thin TF seed, fat GitOps layer.**

- **Terraform owns the seed only**: `infra/cluster` (k3d) + `infra/platform`
  (ArgoCD install + the minimal bootstrap creds ArgoCD needs to reach Git).
- **ArgoCD owns everything above**: Garage, Loki, Vault, observability, Forgejo,
  all app workloads, as `Application`s sourced from `apps/` in the GitHub repo.
- No `helm_release` for workloads. `infra/platform` shrinks to essentially the
  ArgoCD install.
- Ordering across apps: not TF `depends_on`. Planned as ArgoCD sync waves; as built, each consumer retries until its dependency is ready (see Consequences).
- Imperative one-shots inside a workload (e.g. Garage layout/bucket/key init)
  = Kubernetes Jobs with an ArgoCD `PostSync` hook, kept idempotent.

```mermaid
flowchart TB
  subgraph GIT["Git source of truth (GitHub)"]
    APPS["apps/*  (desired state)"]
  end
  subgraph ARGO["ArgoCD layer: GitOps (continuous reconcile)"]
    G["Garage"]:::app
    L["Loki"]:::app
    V["Vault"]:::app
    O["Prometheus / Grafana"]:::app
    F["Forgejo"]:::app
  end
  subgraph TF["Terraform seed (snapshot apply)"]
    ARGOCD["ArgoCD install\n(infra/platform)"]:::seed
    CLUSTER["k3d cluster\n(infra/cluster)"]:::seed
  end
  HOST["Host / Docker"]

  APPS -->|Argo pulls & reconciles| ARGO
  ARGOCD -->|installs, then hands off| ARGO
  CLUSTER --> ARGOCD
  HOST --> CLUSTER
  classDef app fill:#1f6feb22,stroke:#1f6feb;
  classDef seed fill:#8957e522,stroke:#8957e5;
```

## Rationale

- **TF is a snapshot applier; ArgoCD is a continuous reconciler.** Workloads
  want audit, revert, drift-detection, self-heal, which is ArgoCD's job. TF
  managing runtime apps causes plan/apply drift against a live cluster, puts
  cluster credentials in the TF runner, and gives no continuous reconcile.
- **The seed cannot be GitOps.** ArgoCD cannot install itself before it exists,
  and cannot manage the cluster it runs on. That layer is TF's, and only that.
- **Gray-zone test:** *does ArgoCD need it to function?* Yes (the cluster,
  ArgoCD itself, the Git cred) → seed/TF. No (Garage, Loki, Vault, …) → GitOps.
- **Sequencing consequence:** Garage is a workload, so it deploys as an Argo
  app and therefore cannot precede ArgoCD. Build order: ArgoCD first, then
  Garage.

## Bootstrap: GitHub, not in-cluster Forgejo

- The **cold-start source stays external** (GitHub, or a local git bundle),
  independent of cluster state. ArgoCD is not limited to GitHub (Forgejo is a
  normal, Gitea-compatible Git server Argo supports); the constraint is a
  **bootstrap cycle**, not tooling. Which side is the *primary* source is a
  separate choice (see "Considered, not built" below).
- Sourcing apps from the in-cluster Forgejo that ArgoCD itself deploys is a
  chicken-egg: fresh cluster → Argo up → needs apps from Forgejo → Forgejo not
  deployed yet → deadlock.
- **Day-2 tiering:** Tier 0 (bootstrap: Argo config + Forgejo deploy) stays
  reachable at cold start, GitHub or a local git bundle, **forever**. Tier 1
  (app repos, dev workflow) may migrate to Forgejo once it is up (repoint
  `Application.repoURL`; Argo can watch GitHub and Forgejo in parallel).

## Considered, not built: Forgejo as primary source

Push to Forgejo, mirror to GitHub, and point day-2 `Application`s at Forgejo so reconcile survives a GitHub outage. Not built: it makes Forgejo (one pod, one PV) a single point of failure that needs its own backups; here Forgejo is only a sample stateful app.

## Consequences

- `infra/platform` shrinks to ~just ArgoCD; most prior "platform via helm"
  intent moves to `apps/`. Amends ADR-0001's platform scope.
- Cross-app ordering: no sync waves (ordering whole `Application`s in an
  app-of-apps needs a custom health check). Consumers retry instead: Loki's
  Vault agent waits for the key, Loki retries Garage. Vault seeding is a
  local step (`mise run vault`) after Garage init, so the rebuild order
  is fixed there.
- Imperative bootstraps (Garage init) need idempotent PostSync-hook Jobs.
- Webhook race on a fresh rebuild (Vault consumer created before the injector): fixed by a targeted restart in `mise run vault`, not sync waves, because Vault stays NotReady until the manual unseal (ADR-0004).
- Rejected: TF `helm_release` for all workloads (drift, creds-in-TF, no
  reconcile); a second in-cluster Git as the bootstrap source (chicken-egg).

## Related

ADR-0001 (repo layout / state boundary; this ADR refines its platform scope).
ADR-0002 (Garage object store).
