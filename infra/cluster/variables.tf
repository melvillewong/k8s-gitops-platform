variable "cluster_name" {
  description = "The name of the cluster"
  type        = string
  default     = "mycluster"
}

variable "agent_count" {
  description = "The number of agents in the cluster"
  type        = number
  default     = 3
}

variable "k3s_version" {
  description = "k3s image tag (pins the k8s version)"
  type        = string
  default     = "v1.36.2-k3s1"
}
