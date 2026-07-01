output "kubeconfig_path" {
  value = abspath("${path.module}/kubeconfig.yaml")
}
output "context" {
  value = "k3d-${var.cluster_name}"
}
