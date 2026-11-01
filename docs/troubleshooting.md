# Troubleshooting

Problems hit while building. Symptom, cause, fix.

## Ingress / DNS

### Ingress host fails in browser, works in cluster

- **Check**: `curl -H 'Host: <name>' http://127.0.0.1:8080/` = 200 means cluster is fine, local DNS is not.
- **Note**: ingress `172.19.0.x` unreachable from host; use k3d ports `8080` (http) / `8443` (https).

### `*.local` in `/etc/hosts` never resolves

- **Cause**: `.local` = mDNS; `nsswitch.conf` runs `mdns_minimal [NOTFOUND=return]` before `files`.
- **Fix**: use `*.localhost` (resolves to 127.0.0.1, no config).

## ArgoCD

### `ComparisonError: authentication required: Repository not found`

- **Cause**: private repo, no creds.
- **Fix**: create the labelled repo Secret with kubectl (`mise run secrets`, see `docs/runbooks/rebuild.md`); no ArgoCD login needed.

### App sync status `Unknown`

- **Meaning**: ArgoCD cannot read Git, so it has no desired state to compare. See `kubectl -n argocd describe application <app>` (Conditions).
- **Cause 1**: `TLS handshake timeout` = cannot reach GitHub at all (VPN on). Also blocks selfHeal: Argo re-checks Git before reverting, so drift stays until VPN off.
- **Cause 2**: `Write access to repository not granted` = PAT lacks access to the repo (fine-grained: repo not selected or no Contents read).
- **Note**: status only updates on the next poll (~3 min); force with the hard-refresh command below.

### App `Synced` but not on latest commit

- **Cause**: compared against last-polled rev (~3 min poll).
- **Fix**: `kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.

### `argocd` CLI: `server address unspecified`

- **Fix**: `argocd login <host>:<port> --username admin --password <pw> --insecure --grpc-web`.

## Terraform / Helm

### `helm_release.argocd: Still creating...` for minutes

- **Cause**: Helm waits (300s) for pods Ready; pods stuck `ImagePullBackOff`, VPN on (VPN off fixed it).
- **Check**: `kubectl get pods -A | grep -vE 'Running|Completed'`; `ip route get 1.1.1.1` shows your VPN interface (e.g. `tun0`) = VPN on.
- **Fix**: VPN off, clean up release (below), re-run.

### `helm_release.argocd` slow on every rebuild (VPN off)

- **Cause**: normal. `mise run down` deletes the node containers, so every image is pulled again; each node pulls separately, and Helm waits for all pods Ready.
- **Check**: `kubectl -n argocd get events | grep Pulled` shows each pull's time.
- **Speed-up (not done)**: k3d registry cache (pull-through mirror outside the cluster) survives `down`, so rebuilds reuse images. Consider at the DR drill.

### `cannot re-use a name that is still in use`

- **Cause**: earlier apply timed out or Ctrl+C'd; release left `failed` / `pending-install`, not in TF state.
- **Check**: `helm -n argocd list`.
- **Fix**: `helm -n argocd uninstall argocd`, then re-apply. Deleting pods alone does not help.

## Kubernetes

### Pod stuck `Terminating` after suspend/reboot

- **Cause**: kubelet never confirmed container death; StatefulSet can't recreate same-name pod, so apply hangs. Deployments are unaffected: random-suffix pod names let a new pod run beside the stuck one.
- **Fix**: `kubectl -n argocd delete pod <pod> --grace-period=0 --force`. Brief `Terminating` (under 30s) is normal.
- **Caveat**: `--force` assumes the old container is truly dead (safe on single-node k3d after a reboot); on a multi-node cluster with a merely unreachable node it risks two writers.

### Refresh does nothing, apps stuck `Unknown`, pods `Pending`/`Terminating` after suspend

- **Symptom**: `refresh=hard` ignored; `argocd-application-controller-0` `Terminating`, others `Pending`; `kubectl exec` fails `proxy error ... dialing 172.18.0.x:10250, code 502`.
- **Cause**: agent nodes `NotReady` (`kubectl describe node`: "Kubelet stopped posting node status") after suspend. No kubelet = no pod runs or dies, so no app controller = nothing reconciles.
- **Check**: `kubectl get nodes` first; force-deleting pods is pointless while agents are `NotReady`.
- **Fix**: `docker restart k3d-mycluster-agent-0 k3d-mycluster-agent-1 k3d-mycluster-agent-2` (or `k3d cluster stop mycluster && k3d cluster start mycluster`), wait for `Ready`, then force-delete pods still `Terminating`.

### App stays `Progressing` after a rebuild, one node `NotReady`

- **Symptom**: monitoring `Progressing` long after every other app is Healthy; one node-exporter pod `Pending` with only a `Scheduled` event; `kubectl get nodes` shows one agent `NotReady` ("Kubelet stopped posting node status") while `docker ps` shows its container `Up`.
- **Cause**: the k3s agent process exited at start: `docker logs k3d-mycluster-agent-1` shows `failed to start networking: flannel failed to sync address annotations: ... unexpected EOF` (API server still recovering). The k3d entrypoint keeps the container alive, logging `localhost:8080 ... connection refused` forever. A DaemonSet needs a pod on every node, so its app never turns Healthy.
- **Fix**: `docker restart k3d-mycluster-agent-1`; node `Ready` within ~1 min.
- **Prevent**: `mise run up` ends with `kubectl wait node --all --for=condition=Ready`, so the crash fails the rebuild loudly instead of hiding behind `Progressing`.
- **Lesson**: container `Up` does not mean the node runs; check `kubectl get nodes` first when a DaemonSet is stuck.

## Vault

### Loki `CrashLoopBackOff` after a rebuild: `no EC2 IMDS role found`

- **Symptom**: loki app `Progressing`; `loki-0` crash-loops with `init compactor: ... get credentials: failed to refresh cached credentials, no EC2 IMDS role found`; the pod has no `vault-agent-init` init container.
- **Cause**: cross-app race on a fresh rebuild. `loki-0` was created (03:18:33) before the Vault agent injector and its webhook existed (03:18:35), so the API server never called the webhook and the pod went through unchanged. With no `/vault/secrets/aws-credentials`, the AWS SDK falls back to EC2 metadata. `failurePolicy: Fail` only applies once the webhook config exists. Earlier runs were lucky (or Loki was added after Vault was up).
- **Fix**: `mise run vault` (re-run is safe): at the end it restarts pods labelled `vault-inject=true` that have no `vault-agent-init` or are stuck in its backoff; the new pod gets injected. By hand: `kubectl -n logging delete pod loki-0`.
- **Prevent**: already in the rebuild flow (`mise run vault` runs after `up`). Sync waves were rejected (ADR-0003): Vault stays NotReady until unsealed, so later waves would wait on a manual step.
- **Lesson**: a mutating webhook only acts on objects created after it is registered; anything earlier needs a restart.

### `mise run vault`: `Vault is initialised but vault-unseal-keys.json is missing; cannot unseal`

- **Symptom**: `vault-unseal-keys.json` exists but is 0 bytes; its mtime matches the Vault container's start time after a cluster restart.
- **Cause**: the script ran while Vault was still starting. `kubectl wait --for=phase=Running` returns at once (the pod stays `Running`, only the container restarted), `vault status` returned nothing, so `.initialized != "true"` took the init branch. `vault operator init ... > "$KEYS_FILE"` emptied the file before init ran, then init failed (already initialised, exit 2).
- **Fix**: no copy of the unseal key means the data is unreadable; reset: `rm` the empty file, `kubectl -n vault delete pvc data-vault-0 --wait=false` + `delete pod vault-0`, `mise run vault`, restart Grafana and Alertmanager. Every secret is re-seedable (Garage key, `.env` webhook, generated Grafana password).
- **Prevent**: script now waits until `vault status` returns JSON, refuses to init over a non-empty keys file, and writes init output to a `mktemp` file moved into place only on success. Back up the keys file outside the box (password manager).
- **Lesson**: never redirect straight into the only copy of a secret; and pod `Running` does not mean the server answers.

## Monitoring

### `GarageDown` fires on every rebuild, resolves ~5 min later

- **Symptom**: Discord `[FIRING] GarageDown` ~1-2 min after a rebuild finishes, `[RESOLVED]` ~5 min after that; Garage pod Ready the whole time. Same on all 3 DR drills.
- **Cause**: Prometheus started (12:33:15) with a config generated before Garage's ServiceMonitor existed; the operator updated its config Secret, but the reloader saw it only when the kubelet refreshed the mounted file (reload 12:36:21, first scrape 12:36:56). `absent(up{job="garage"} == 1)` was true for 3.5 min, past `for: 2m`. Resolved late because Alertmanager `group_interval: 5m` batches group updates.
- **Fix**: rule ignores Prometheus's first 10 min: `... unless on() (time() - process_start_time_seconds{job="monitoring-kube-prometheus-prometheus", container="prometheus"} < 600)`.
- **Check**: Prometheus logs `Loading configuration file` times vs `ALERTS{alertname="GarageDown"}` history; query via `kubectl get --raw /api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=...` (the image has no `wget`).
- **Lesson**: `absent()` alerts fire on any missing target, including "not configured yet"; ArgoCD Healthy does not mean scraping has started.

### Grafana `GF_SECURITY_ADMIN_PASSWORD__FILE is not supported with the distroless Grafana image`

- **Cause**: chart default image tag is `<version>-distroless`; `__FILE` env needs the image's `/run.sh`, which distroless lacks. Fails at `helm template`.
- **Fix**: `GF_SECURITY_ADMIN_PASSWORD: $__file{/vault/secrets/grafana}`; Grafana expands `$__file{}` itself.

### New Grafana pod `CreateContainerConfigError: secret "monitoring-grafana" not found`

- **Symptom**: after moving the admin password to `grafana.env`, the new pod is stuck, the old pod keeps running (rolling update), app `Progressing`; checks hit the old pod and return `401`.
- **Cause**: setting `env.GF_SECURITY_ADMIN_PASSWORD` stops the chart creating its admin Secret (`templates/secret.yaml` condition) and ArgoCD prunes it, but the admin user (`GF_SECURITY_ADMIN_USER`, sidecars' `REQ_USERNAME`) still references it. The same switch drops the sidecars' `REQ_PASSWORD`, so their reload API calls would `401`.
- **Fix**: `grafana.env.GF_SECURITY_ADMIN_USER: admin`; `sidecar.dashboards.skipReload: true` (Grafana re-reads dashboard files every 30 s); `sidecar.datasources.skipReload: true` + `initDatasources: true`.
- **Check**: `helm template ... | grep -c secretKeyRef` = 0; pick the newest pod with `--sort-by=.metadata.creationTimestamp`.
- **Lesson**: before overriding a chart value, grep the chart's `templates/` for that key; one value can toggle several templates.

### Grafana pod stuck `Init:0/2` after `initDatasources: true`

- **Symptom**: `grafana-init-sc-datasources` logs `Initial sync complete` then repeats `Loading incluster config...` forever; `vault-agent-init` waits `PodInitializing`; old pod keeps running; app `Degraded` after the 10 min progress deadline.
- **Cause**: the init container takes `METHOD` from `sidecar.datasources.watchMethod` (default `WATCH`), which never exits; init containers run in order, so the pod never starts.
- **Fix**: `sidecar.datasources.watchMethod: LIST` (list once, write, exit). Do not delete the old pod: the Deployment removes it once the new one is Ready.

## CI

### Job stays `Queued` forever after the cluster comes back

- **Symptom**: a PR or push started a job while the cluster was down (runner scale set shows offline in GitHub); once ARC is running again, the job never starts.
- **Likely cause**: the job was queued while no ARC listener was connected, and the listener does not pick it up after it reconnects.
- **Fix**: once ARC is up, cancel the run and re-run it in GitHub (`gh run cancel <id>`, then `gh run rerun <id>`).
