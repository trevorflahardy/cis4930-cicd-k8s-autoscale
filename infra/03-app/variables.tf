variable "image" {
  description = "Application image built by CI, e.g. orders-api:<git-sha>. Must exist in the local Docker daemon."
  type        = string
}

variable "namespace" {
  type    = string
  default = "orders"
}

variable "api_min_replicas" {
  type    = number
  default = 2
}

variable "api_max_replicas" {
  type    = number
  default = 8
}

variable "api_cpu_target_percent" {
  description = "Average CPU utilisation (of requests) the HPA steers the API towards."
  type        = number
  default     = 50
}

variable "worker_min_replicas" {
  type    = number
  default = 1
}

variable "worker_max_replicas" {
  type    = number
  default = 10
}

variable "worker_queue_target" {
  description = "Pending orders per worker replica before KEDA adds another worker."
  type        = number
  default     = 10
}

variable "pricing_iterations" {
  description = "PBKDF2 rounds per order: the CPU cost of each POST /orders."
  type        = number
  default     = 50000
}

variable "worker_work_ms" {
  description = "Simulated fulfilment latency per order in the worker."
  type        = number
  default     = 200
}

variable "api_docker_port" {
  description = "Host port (127.0.0.1) for the API running as a plain Docker container."
  type        = number
  default     = 8081
}
