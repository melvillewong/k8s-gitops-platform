# ADR-0002: Self-hosted object store: Garage, and accepting no native state locking

- Status: accepted (amended 02-Jul-26)
- Date: 01-Jul-26

## Amendment (02-Jul-26): Garage is data-plane only; state stays local

Superseded the "Garage as Terraform state backend" decision below. Garage no
longer holds Terraform state. Both `infra/cluster` and `infra/platform` keep
**local** state.

- **Why the flip:** storing `infra/platform` state inside the very cluster that
  state provisions is a circular dependency (Garage down → no `terraform` to
  repair it), the same chicken-egg that already forces `infra/cluster` local.
  A remote S3 backend with locking and versioning would add complexity
  (two-phase bootstrap, no-lock caveat) and show nothing new.
- **Garage now justifies itself as a runtime data-plane store**, not a state
  store. Sole confirmed consumer: **Loki chunks**, a write-once /
  immutable-blob workload Garage serves cleanly. Forgejo blobs stay on local
  PV (S3 adds little there).
- **Net effect on the locking gap:** moot for state (no state in Garage). The
  no-consensus / no-`If-None-Match` limitation only ever mattered for a mutable,
  locked object; Loki chunks need no mutual exclusion.
- **Kept:** Garage over MinIO (below). **Dropped:** the `s3` backend block,
  `use_lockfile` discussion as a live concern, and the state-migration bootstrap.

## Re-check (01-Oct-26): still no locking; why object storage at all

- **Why object storage, not a database:** Loki stores chunks (and its TSDB
  index) in object storage or on a filesystem only; filesystem is "not
  recommended" for production. Postgres is not a Loki backend; Cassandra is
  deprecated. Chunks are large immutable blobs, the object-store use case.
- **Garage status unchanged:** S3 compatibility page still lists object lock
  endpoints and bucket versioning as "Missing". Sept 2026 third-party reports:
  `PutObject` ignores `If-None-Match` / `If-Match` (CRDT design, no
  compare-and-swap). Garage's own release notes were not reachable to confirm.
- **Later consumers (all write-once):** backups (Forgejo PV and Vault
  snapshots via restic/Velero), Forgejo LFS/attachments, traces if Tempo is
  added. Still never Terraform state.

<details>
<summary>Original decision (01-Jul-26), superseded for Terraform state</summary>

## Context

The platform needs a self-hosted, S3-compatible object store for the Terraform
`s3` state backend and later for Loki chunks and backups.

MinIO was the original pick, but its community edition lost features (May 2025), stopped shipping images (Oct 2025) and was archived (25-Apr-26), with no guaranteed security patches.

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
- **The limitation is confined to Terraform state.** Every other object-store use in the
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

</details>

## Related

ADR-0001 (state boundary: only `infra/platform` state lives in the store).
