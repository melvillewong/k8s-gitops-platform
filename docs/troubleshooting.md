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
- **Fix**: `argocd repo add https://github.com/<owner>/<repo>.git --username <user> --password <PAT>`.

### App sync status `Unknown`

- **Meaning**: ArgoCD cannot read Git, so it has no desired state to compare. See `kubectl -n argocd describe application <app>` (Conditions).
- **Cause 1**: `TLS handshake timeout` = cannot reach GitHub at all (VPN on).
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

### `cannot re-use a name that is still in use`

- **Cause**: earlier apply timed out or Ctrl+C'd; release left `failed` / `pending-install`, not in TF state.
- **Check**: `helm -n argocd list`.
- **Fix**: `helm -n argocd uninstall argocd`, then re-apply. Deleting pods alone does not help.

## Kubernetes

### Pod stuck `Terminating` after suspend/reboot

- **Cause**: kubelet never confirmed container death; StatefulSet can't recreate same-name pod, so apply hangs.
- **Fix**: `kubectl -n argocd delete pod <pod> --grace-period=0 --force`. Brief `Terminating` (under 30s) is normal.
