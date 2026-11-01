# ADR-0007: Trivy scanning in PR validation

- Status: accepted
- Date: 01-Nov-26

## Context

In GitOps, merge = deploy, so the PR is the only gate. `pr-validate` already checks that Terraform and manifests are valid, but not that they are safe: a `privileged: true` container or a root pod would merge unnoticed. The repo builds no images; every image comes from an upstream chart or manifest.

## Decision

**A `trivy` job in `pr-validate` runs two scans, with different rules.**

- **Config scan, blocking**: `trivy config` on `infra/`, `apps/` and the rendered Helm charts fails the PR on HIGH/CRITICAL misconfigurations. Charts are scanned as rendered (`helm template`), because only the render holds the real security context and images.
- **Image scan, report-only**: `trivy image` on every `image:` in the manifests and renders prints fixable HIGH/CRITICAL CVEs and never fails the job. Upstream images have no rebuild path here; the fix is a chart or tag bump.
- Trivy is installed from a pinned, checksum-verified release tarball. The vulnerability DB and checks bundle are cached per day, saved by runs on `main` and only restored by PRs.
- Accepted findings live in `.trivyignore.yaml`: one rule in one file per entry, with a reason and an expiry date.

## Rejected

- **`aquasecurity/trivy-action@master`**: an unpinned third-party action runs with the job's token; a pinned tarball with a checksum cannot change under us.
- **Blocking image scan**: every PR would go red over upstream CVEs that no change in this repo can fix.
- **Plain `.trivyignore`**: ignores a rule in every file, including files added later, with no reason or expiry.

## Consequences

- **First run**: 16 config findings (1 CRITICAL, 15 HIGH). 10 fixed (Vault and Garage pods non-root with read-only root filesystems, Helm test pod skipped), 6 accepted with reasons in 5 ignore entries.
- **Image CVEs visible, not blocked**: 217 fixable HIGH/CRITICAL CVEs across 7 images on the first run. Reviewed on version bumps, not per PR.
- **Accepted findings expire on 01-May-27**: an expired entry turns the check red again, forcing a review.
- **Not scanned**: kube-prometheus-stack, alloy and arc-controller are not rendered in `pr-validate`.

## Related

ADR-0005 (CI). `.github/workflows/pr-validate.yml`, `.trivyignore.yaml`.
