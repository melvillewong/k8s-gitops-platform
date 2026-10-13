data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = "../cluster/terraform.tfstate" }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.2.1"
  namespace        = "argocd"
  create_namespace = true
  values           = [file("${path.module}/values/argocd.yml")]
}

resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.5"
  namespace  = helm_release.argocd.namespace
  values     = [file("${path.module}/values/argocd-apps.yml")]
  depends_on = [helm_release.argocd] # because: Application CRD must exist first
}
