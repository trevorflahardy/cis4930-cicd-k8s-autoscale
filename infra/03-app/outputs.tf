output "namespace" {
  value = kubernetes_namespace_v1.orders.metadata[0].name
}

output "image" {
  value = var.image
}

output "api_url" {
  value = local.platform.api_url
}

output "migration_job" {
  value = kubernetes_job_v1.migrate.metadata[0].name
}

output "api_docker_url" {
  description = "API served by the kreuzwerker/docker-managed container."
  value       = "http://127.0.0.1:${var.api_docker_port}"
}

output "api_docker_container" {
  value = docker_container.api.name
}
