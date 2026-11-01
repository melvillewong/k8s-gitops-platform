# GarageDown

## What it means

No healthy Garage scrape target for 2 minutes (`absent(up{job="garage"} == 1)`). Garage is Loki's only chunk store: Loki keeps buffering chunks in memory and WAL, but nothing is flushed until Garage is back. Logs are not lost yet; a long outage risks ingester memory and WAL disk.

## Check

```bash
kubectl -n storage get pod garage-0 -o wide          # Running? Ready? restarts?
kubectl -n storage describe pod garage-0              # Events: scheduling, probes, OOMKilled
kubectl -n storage logs garage-0 --tail=50            # config or RPC errors
kubectl -n storage get pvc                            # meta + data Bound?
kubectl -n argocd get app garage                      # Synced? a bad commit?
kubectl -n storage exec garage-0 -- /garage status    # node up, layout applied
```

## Common causes

| Cause | Sign | Fix |
|---|---|---|
| Replicas 0 or bad manifest in Git | app `Synced`, no pod or old spec | revert the commit, push |
| Pod `Pending` | Events: PVC or node | node `Ready`? (`docker restart` agents after suspend), PVC `Bound` |
| `CrashLoopBackOff` | logs: config parse, `rpc_secret` | fix `garage-config` or Secret `garage-rpc`; bump `config-rev` |
| `OOMKilled` | describe: last state | raise `limits.memory` in the StatefulSet |
| Metrics port only | pod Ready, `up == 0` | `[admin] api_bind_addr` present, Service port `admin` |
| Fresh Prometheus (rebuild or restart), not an outage | Garage pod fine; no `garage` job yet in Prometheus targets | none: the rule ignores Prometheus's first 10 min; if it still fires, see `docs/troubleshooting.md` (GarageDown on every rebuild) |

"Resolved" arrives up to ~5 min late: Alertmanager `group_interval: 5m` sends group updates at most every 5 min. Recovery time = the `up{job="garage"}` graph, not the Discord timestamp.

## Verify recovery

- Prometheus: `up{job="garage"}` = `1`, `cluster_healthy` = `1`
- Discord: `[RESOLVED] GarageDown` message
- Loki: ingester flush errors stop
