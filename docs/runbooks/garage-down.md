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

## Verify recovery

- Prometheus: `up{job="garage"}` = `1`, `cluster_healthy` = `1`
- Discord: `[RESOLVED] GarageDown` message
- Loki (task-07): ingester flush errors stop
