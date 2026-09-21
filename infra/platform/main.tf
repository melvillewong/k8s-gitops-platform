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
