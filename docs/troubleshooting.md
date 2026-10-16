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
- **Fix**: create the labelled repo Secret with kubectl (`note.md` Rebuild flow step 3); no ArgoCD login needed.

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
- **Check**: `kubectl get pods -A | grep -vE 'Running|Completed'`; `ip route get 1.1.1.1` shows `tun0` = VPN on.
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

- **Cause**: kubelet never confirmed container death; StatefulSet can't recreate same-name pod, so apply hangs.
- **Fix**: `kubectl -n argocd delete pod <pod> --grace-period=0 --force`. Brief `Terminating` (under 30s) is normal.

### Refresh does nothing, apps stuck `Unknown`, pods `Pending`/`Terminating` after suspend

- **Symptom**: `refresh=hard` ignored; `argocd-application-controller-0` `Terminating`, others `Pending`; `kubectl exec` fails `proxy error ... dialing 172.18.0.x:10250, code 502`.
- **Cause**: agent nodes `NotReady` (`kubectl describe node`: "Kubelet stopped posting node status") after suspend. No kubelet = no pod runs or dies, so no app controller = nothing reconciles.
- **Check**: `kubectl get nodes` first; force-deleting pods is pointless while agents are `NotReady`.
- **Fix**: `docker restart k3d-mycluster-agent-0 k3d-mycluster-agent-1 k3d-mycluster-agent-2` (or `k3d cluster stop mycluster && k3d cluster start mycluster`), wait for `Ready`, then force-delete pods still `Terminating`.

## Monitoring

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
