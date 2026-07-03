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

variable "port_http" {
  description = "host port to k3d loadbalancer port mapping for HTTP traffic"
  type        = string
  default     = "8080:80@loadbalancer"
}

variable "port_https" {
  description = "host port to k3d loadbalancer port mapping for HTTPS traffic"
  type        = string
  default     = "8443:443@loadbalancer"
}
