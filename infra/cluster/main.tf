resource "null_resource" "cluster" {
  triggers = {
    cluster_name = var.cluster_name
    agent_count  = var.agent_count
    k3s_version  = var.k3s_version
  }
  provisioner "local-exec" {
    when    = create
    command = "k3d cluster create ${self.triggers.cluster_name} --agents ${self.triggers.agent_count} --image rancher/k3s:${self.triggers.k3s_version} --wait"
  }
  provisioner "local-exec" {
    when    = create
    command = "k3d kubeconfig get ${self.triggers.cluster_name} > ${abspath(path.module)}/kubeconfig.yaml"
  }
  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.triggers.cluster_name}"
  }
}
