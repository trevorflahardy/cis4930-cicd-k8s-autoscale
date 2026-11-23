# Stage 1: platform.
#   * a kind Kubernetes cluster (compute tier; its nodes are Docker containers)
#   * Postgres and Redis as Docker containers with named volumes (data tier)
# Both tiers share the "kind" Docker network so pods can reach the databases.

locals {
  kind_network    = "kind"
  kubeconfig_path = abspath("${path.root}/../../.kube/${var.cluster_name}.kubeconfig")

  # kind names nodes <cluster>-control-plane, <cluster>-worker, <cluster>-worker2, ...
  node_names = concat(
    ["${var.cluster_name}-control-plane"],
    [for i in range(var.worker_count) : i == 0 ? "${var.cluster_name}-worker" : "${var.cluster_name}-worker${i + 1}"],
  )
}

# ---------------------------------------------------------------- compute tier

resource "kind_cluster" "this" {
  name            = var.cluster_name
  wait_for_ready  = true
  kubeconfig_path = local.kubeconfig_path

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      extra_port_mappings {
        container_port = var.api_node_port
        host_port      = var.api_host_port
        listen_address = "127.0.0.1"
        protocol       = "TCP"
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}

# ------------------------------------------------------------------ data tier

resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "docker_image" "postgres" {
  name         = var.postgres_image
  keep_locally = true
}

resource "docker_image" "redis" {
  name         = var.redis_image
  keep_locally = true
}

resource "docker_volume" "postgres_data" {
  name = "${var.cluster_name}-postgres-data"
}

resource "docker_volume" "redis_data" {
  name = "${var.cluster_name}-redis-data"
}

resource "docker_container" "postgres" {
  name    = "${var.cluster_name}-postgres"
  image   = docker_image.postgres.name
  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=orders",
    "POSTGRES_USER=orders",
    "POSTGRES_PASSWORD=${random_password.postgres.result}",
  ]

  networks_advanced {
    name    = local.kind_network
    aliases = ["postgres"]
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U orders -d orders"]
    interval = "5s"
    timeout  = "3s"
    retries  = 12
  }

  wait         = true
  wait_timeout = 90

  # The "kind" network is created by kind; it must exist before we attach to it.
  depends_on = [kind_cluster.this]
}

resource "docker_container" "redis" {
  name    = "${var.cluster_name}-redis"
  image   = docker_image.redis.name
  restart = "unless-stopped"

  # Append-only persistence so queued orders survive a Redis restart.
  command = [
    "redis-server",
    "--appendonly", "yes",
    "--requirepass", random_password.redis.result,
  ]

  networks_advanced {
    name    = local.kind_network
    aliases = ["redis"]
  }

  volumes {
    volume_name    = docker_volume.redis_data.name
    container_path = "/data"
  }

  healthcheck {
    test     = ["CMD-SHELL", "redis-cli --no-auth-warning -a \"$${REDIS_PASSWORD}\" ping | grep -q PONG"]
    interval = "5s"
    timeout  = "3s"
    retries  = 12
  }

  env = ["REDIS_PASSWORD=${random_password.redis.result}"]

  wait         = true
  wait_timeout = 90

  depends_on = [kind_cluster.this]
}
