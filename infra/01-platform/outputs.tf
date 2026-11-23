output "cluster_name" {
  value = kind_cluster.this.name
}

output "kubeconfig_path" {
  value = kind_cluster.this.kubeconfig_path
}

output "kube_context" {
  value = kind_cluster.this.context_name
}

output "endpoint" {
  value = kind_cluster.this.endpoint
}

output "client_certificate" {
  value     = kind_cluster.this.client_certificate
  sensitive = true
}

output "client_key" {
  value     = kind_cluster.this.client_key
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = kind_cluster.this.cluster_ca_certificate
  sensitive = true
}

output "node_names" {
  description = "kind node containers; stage 3 imports the app image into each."
  value       = local.node_names
}

output "docker_network" {
  value = local.kind_network
}

output "postgres_container" {
  value = docker_container.postgres.name
}

output "redis_container" {
  value = docker_container.redis.name
}

output "postgres_ip" {
  value = one([for n in docker_container.postgres.network_data : n.ip_address if n.network_name == local.kind_network])
}

output "redis_ip" {
  value = one([for n in docker_container.redis.network_data : n.ip_address if n.network_name == local.kind_network])
}

output "postgres_password" {
  value     = random_password.postgres.result
  sensitive = true
}

output "redis_password" {
  value     = random_password.redis.result
  sensitive = true
}

output "api_node_port" {
  value = var.api_node_port
}

output "api_url" {
  value = "http://127.0.0.1:${var.api_host_port}"
}
