output "metrics_server_version" {
  value = helm_release.metrics_server.metadata.app_version
}

output "keda_version" {
  value = helm_release.keda.metadata.app_version
}
