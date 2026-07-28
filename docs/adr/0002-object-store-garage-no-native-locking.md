# ADR-0002: Self-hosted object store — Garage, and accepting no native state locking

- Status: accepted (amended 02-07-2026)
- Date: 01-07-2026

## Amendment (02-07-2026): Garage is data-plane only; state stays local

Superseded the "Garage as Terraform state backend" decision below. Garage no
longer holds Terraform state. Both `infra/cluster` and `infra/platform` keep
**local** state.

- **Why the flip:** storing `infra/platform` state inside the very cluster that
  state provisions is a circular dependency (Garage down → no `terraform` to
  repair it), the same chicken-egg that already forces `infra/cluster` local.
  Remote S3 backend + locking + versioning are already demonstrated in the
  `learn-terraform` CV entry, so building them again here added complexity
  (two-phase bootstrap, no-lock caveat) for zero new signal.
- **Garage now justifies itself as a runtime data-plane store**, not a state
  store. Sole confirmed consumer: **Loki chunks (Task 07)**, a write-once /
  immutable-blob workload Garage serves cleanly. Forgejo blobs stay on local
  PV (S3 adds little there).
- **Net effect on the locking gap:** moot for state (no state in Garage). The
  no-consensus / no-`If-None-Match` limitation only ever mattered for a mutable,
  locked object; Loki chunks need no mutual exclusion.
- **Kept:** Garage over MinIO (below). **Dropped:** the `s3` backend block,
  `use_lockfile` discussion as a live concern, and the state-migration bootstrap.
- CV bullet is now data-plane: "self-hosted S3-compatible object store backing
  Loki log chunks", non-dup with the AWS S3 state-backend entry.

The original decision text below is retained for history.

## Context

The platform needs a self-hosted, S3-compatible object store for the Terraform
`s3` state backend (Task 02) and later for Loki chunks (Task 07) and backups.

MinIO was the original pick. It is now unusable as an open dependency:

- May 2025: breaking release stripped management features from the community
  edition.
- Oct 2025: stopped publishing community Docker images / binaries.
- Dec 2025: co-founder set the repo README to "maintenance mode".
- 25-04-2026: `minio/minio` archived, read-only. No new features, no
  guaranteed security patches; official redirect is proprietary AIStor.

Building a portfolio on an archived, unpatched store is a poor security and
maintenance story. We need a maintained, self-hostable S3 replacement.

## Decision

Use **Garage** (Deuxfleurs, Rust) as the single self-hosted object store, and
**accept that Terraform native state locking is unavailable** (option A).

- Single-node deploy in `infra/platform/`: `replication_factor = 1`, S3 API on
  `:3900`, `s3_region = "garage"`, LMDB metadata + a data PVC.
- Backend uses `use_path_style = true` and the AWS skip-flags; it does **not**
  set `use_lockfile`, and does not use DynamoDB. State is stored, not locked.
- Mitigate the gaps: single operator (no concurrent `apply`), plus an
  out-of-band backup of the state object to offset Garage's lack of bucket
  versioning.

## Rationale

- **Garage cannot do safe state locking, by design.** TF `use_lockfile` (1.11+)
  relies on `PutObject` + `If-None-Match` for mutual exclusion. Garage's own
  Known Issues page: "structurally impossible to implement in Garage due to the
  lack of a consensus algorithm, which is one of Garage's core design choices
  which we cannot reconsider." So a lock cannot be safely acquired; enabling it
  would give false confidence, not safety.
- **Acceptable here because it is a single-operator platform.** The only thing
  locking buys is protection against concurrent writers, which do not exist on a
  one-person homelab. Documenting the tradeoff is a stronger signal than
  toggling a flag that cannot work.
- **The limitation is confined to Task 02.** Every other object-store use in the
  project (Loki chunks, backups, optional Thanos blocks, Forgejo blobs) is a
  write-once / immutable-blob pattern with no mutual-exclusion need, which Garage
  serves cleanly. Garage is a common, documented Loki and backup target.
- Rejected alternatives:
  - *MinIO / maintained MinIO fork*: keeps `If-None-Match` locking + versioning,
    but re-anchors on an archived upstream (MinIO) or an unproven fork; weaker
    long-term and security story than a maintained project.
  - *RustFS*: too new (2024-25), thinly audited; undercuts a security-focused
    portfolio.
  - *SeaweedFS / Ceph RGW*: heavier multi-component architecture, overkill for a
    KB-sized state object; more surface to secure and operate.

## Consequences

- No backend-level protection against concurrent `terraform apply`. Mitigated by
  operator discipline now; at team scale the fix is a CAS-capable store (real
  AWS S3, Ceph RGW) or a separate lock service, not Garage.
- No S3 bucket versioning, so no built-in state rollback. Mitigated by an
  out-of-band state backup.
- The `s3` backend `region` is a required-but-cosmetic `"garage"`; creds are a
  Garage-issued access/secret key, not MinIO root user/password.
- CV bullet drops any "locking" claim: it says "self-hosted S3-compatible state
  backend", not "native locking without DynamoDB".

## Related

ADR-0001 (state boundary: only `infra/platform` state lives in the store).
`docs/tasks/task-03-garage-object-store.md`; `docs/project.md` Decisions.
