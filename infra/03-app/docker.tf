# The application image deployed as a standalone Docker container with the
# kreuzwerker/docker provider, alongside the Kubernetes deployment. It joins the
# same "kind" Docker network and reaches Postgres and Redis by container alias
# (no IPs), sharing the data tier with the Kubernetes pods. Exposed on
# 127.0.0.1:<api_docker_port> for direct verification.

resource "docker_image" "app" {
  name         = var.image
  keep_locally = true
}

resource "docker_container" "api" {
  name    = "${local.platform.cluster_name}-api-docker"
  image   = docker_image.app.name
  restart = "unless-stopped"

  env = [
    "PG_HOST=postgres",
    "PG_PORT=5432",
    "PG_DB=orders",
    "PG_USER=orders",
    "PG_PASSWORD=${local.platform.postgres_password}",
    "REDIS_HOST=redis",
    "REDIS_PORT=6379",
    "REDIS_PASSWORD=${local.platform.redis_password}",
    "PRICING_ITERATIONS=${var.pricing_iterations}",
    "APP_VERSION=${local.image_tag}",
  ]

  networks_advanced {
    name = local.platform.docker_network
  }

  ports {
    internal = 8000
    external = var.api_docker_port
    ip       = "127.0.0.1"
  }

  read_only = true
  capabilities {
    drop = ["ALL"]
  }

  # Uses the HEALTHCHECK baked into the image (GET /health).
  wait         = true
  wait_timeout = 90

  # Schema must exist before the API serves traffic.
  depends_on = [kubernetes_job_v1.migrate]
}
