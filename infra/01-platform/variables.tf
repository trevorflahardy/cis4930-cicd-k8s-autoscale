variable "cluster_name" {
  description = "Name of the kind cluster; also prefixes the data-tier containers and volumes."
  type        = string
  default     = "orders"
}

variable "worker_count" {
  description = "Number of kind worker nodes (in addition to the control plane)."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 4
    error_message = "worker_count must be between 0 and 4."
  }
}

variable "api_host_port" {
  description = "Host port (bound to 127.0.0.1) that forwards to the API NodePort."
  type        = number
  default     = 8080
}

variable "api_node_port" {
  description = "Kubernetes NodePort the API Service listens on inside the cluster."
  type        = number
  default     = 30080
}

variable "postgres_image" {
  type    = string
  default = "postgres:17-alpine"
}

variable "redis_image" {
  type    = string
  default = "redis:8-alpine"
}
