provider "kubernetes" {
  config_path    = data.terraform_remote_state.cluster.outputs.kubeconfig_path
  config_context = data.terraform_remote_state.cluster.outputs.context
}
provider "helm" {
  kubernetes = {
    config_path    = data.terraform_remote_state.cluster.outputs.kubeconfig_path
    config_context = data.terraform_remote_state.cluster.outputs.context
  }
}
