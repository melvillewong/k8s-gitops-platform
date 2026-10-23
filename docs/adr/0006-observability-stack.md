# ADR-0006: Observability with kube-prometheus-stack, Loki on Garage and Alloy

- Status: accepted
- Date: 23-Oct-26 (decided 18-Sep-26; built in task-06 and task-07)

## Context

The platform needs metrics, logs and alerts that reach a person, all delivered by GitOps like every other workload (ADR-0003). Constraints: one box with shared RAM, no cloud account, and Garage already in place as the object store (ADR-0002). An alert nobody receives is not alerting, so the path must end in a notification with a runbook.

## Decision

**kube-prometheus-stack for metrics and alerting, Loki single-binary on Garage S3 for logs, Grafana Alloy as the log collector.**

- **Metrics**: `kube-prometheus-stack` (chart 92.6.0) as one ArgoCD app: Prometheus Operator, Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics. Scrape targets and rules are CRDs (`ServiceMonitor`, `PrometheusRule`) kept next to each workload in Git (`apps/garage/`). Prometheus: 7d retention, 4GB size cap, 5Gi PVC.
- **Logs**: Loki chart 7.3.0, `deploymentMode: SingleBinary`, 1 replica; TSDB index and chunks in Garage bucket `loki-chunks`; 7d retention via the compactor. S3 key from Vault (ADR-0004).
- **Collector**: Alloy DaemonSet tails `/var/log/pods` on each node, labels streams with `namespace`, `pod`, `container`, `app` only (low cardinality), pushes to Loki.
- **One UI**: Grafana holds both datasources (Prometheus, Loki); dashboards are ConfigMaps in Git.

## Alerting path

- Rule in Git (`PromQL`) -> Prometheus evaluates -> Alertmanager -> Discord webhook (URL rendered from Vault, never in Git).
- Only `severity: critical` routes to Discord; the chart's ~90 warning rules and the always-firing `Watchdog` go to a null receiver.
- Every alert carries a `runbook_url` to `docs/runbooks/` (e.g. `garage-down.md`).
- `send_resolved: true` closes the loop. `group_wait: 30s`, `group_interval: 5m` (updates, including "resolved", batch to at most every 5 min), `repeat_interval: 4h`.
- Example: `GarageDown` = `absent(up{job="garage"} == 1)` for 2m, so a scaled-down pod (gone from Endpoints, no `up == 0`) still alerts. Measured time-to-alert: 3 min 33 s.

## Rejected

- **Loki on the local filesystem**: simplest, but chunks die with the PVC and nothing exercises object storage; Garage already exists for this (ADR-0002).
- **Loki simple-scalable or microservices mode**: read/write/backend split needs several replicas and a cache tier; single-binary covers one box's log volume.
- **ELK / OpenSearch**: full-text index on every word; several GB of RAM for a homelab's logs. Loki indexes labels only and filters lines at query time.
- **Promtail**: end-of-life; Alloy is its replacement and also speaks OpenTelemetry.
- **Managed SaaS (Grafana Cloud, Datadog)**: data leaves the box and nothing about running the stack is learned.

## Consequences

- **Single replicas**: Loki, Prometheus and Alertmanager each run 1 pod. Loki down = no log queries (Alloy retries the push); Garage down = Loki buffers chunks in its WAL, recent logs still queryable.
- **No TLS** between components or on the UIs. Accepted: in-cluster LAN homelab; prod would add cert-manager.
- **Nothing watches the watchers**: `Watchdog` is routed to null, so if Prometheus or Alertmanager dies, no alert says so. Prod: route `Watchdog` to a dead-man's-switch service that pages when the heartbeat stops.
- **Start-up noise**: a fresh Prometheus loads Garage's scrape job only after the operator's config Secret reaches the pod (~3 min in the DR drill). `GarageDown` ignores Prometheus's first 10 min (`unless on() (time() - process_start_time_seconds{...} < 600)`); an outage in that window alerts late.
- **ArgoCD Healthy is not "observability working"**: Healthy covers pods and Deployments, not whether scraping or log ingestion has started.
- **7d retention** for both metrics and logs: enough for homelab debugging; long-term storage (Thanos/Mimir, longer Loki retention) not needed.

## Related

ADR-0002 (Garage), ADR-0003 (delivery), ADR-0004 (Vault secrets for Loki, Grafana, Alertmanager). `docs/tasks/task-06-prometheus-grafana.md`, `docs/tasks/task-07-loki-logs.md`, `docs/runbooks/garage-down.md`.
