# ADR-0001: Repo layout and Terraform state boundary

- Status: accepted
- Date: 30-Jun-26

## Context

Terraform spans two concerns: imperative cluster bootstrap (k3d via
`local-exec`, no real state) and declarative in-cluster platform (`helm`/
`kubernetes` providers). The providers need a kubeconfig that does not exist
until the cluster is created, so a single state can fail on a clean first
apply. App workloads are a third concern, owned by ArgoCD, not Terraform.

## Decision

Layout (grouped by owning tool):

```
infra/cluster/    # k3d via local-exec; outputs kubeconfig
infra/platform/   # helm/kubernetes; consumes kubeconfig
apps/             # GitOps manifests, reconciled by ArgoCD (not IaC)
```

- `infra/cluster` and `infra/platform` = **separate root modules, separate
  state**; platform consumes cluster's kubeconfig output.
- `infra/` = the IaC boundary. `apps/` = not IaC (Git + ArgoCD, no TF state).
  TF owns up to and including ArgoCD; ArgoCD owns `apps/`.

## Rationale

- Separate cluster/platform state fixes the bootstrap chicken-and-egg
  structurally. Rejected: two-stage `-target` (manual/hacky); single state +
  static path + `depends_on` (flaky on first run, `depends_on` orders apply not
  provider init).
- Nesting under `infra/` encodes the TF-vs-ArgoCD boundary; 2 levels, room for
  `infra/dns` etc.

## Consequences

- "One command" = a thin wrapper running both applies in order, not one
  `terraform apply`. Acceptable.
- Two states to wire (kubeconfig output -> input).

## Related

ADR-0002 (Garage; both states stay local). ADR-0003 (`infra/platform` shrinks
to the ArgoCD install; all workloads move to `apps/`).
