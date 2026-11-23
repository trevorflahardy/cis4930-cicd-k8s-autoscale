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
