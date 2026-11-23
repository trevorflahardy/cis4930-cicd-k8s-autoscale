# Stage 3: the application.
#   image load -> namespace/config/secrets -> data-tier Services -> migration Job
#   -> API + worker Deployments -> HPA (CPU) + KEDA ScaledObject (queue depth)

locals {
  image_tag = element(split(":", var.image), length(split(":", var.image)) - 1)

  common_labels = {
    "app.kubernetes.io/part-of"    = "orders"
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/version"    = local.image_tag
  }

  api_labels    = { "app.kubernetes.io/name" = "orders-api" }
  worker_labels = { "app.kubernetes.io/name" = "orders-worker" }
}

# ------------------------------------------------------------- image delivery
# kind nodes run containerd, not the host Docker daemon. Stream the CI-built image
# into every node (equivalent to `kind load docker-image`, without the kind CLI).

resource "terraform_data" "image_load" {
  triggers_replace = {
    image = var.image
    nodes = join(",", local.platform.node_names)
  }

  provisioner "local-exec" {
    command = "bash \"${path.module}/../../scripts/load-image.sh\""
    environment = {
      IMAGE = var.image
      NODES = join(" ", local.platform.node_names)
    }
  }
}

# ------------------------------------------------------- namespace and config

resource "kubernetes_namespace_v1" "orders" {
  metadata {
    name   = var.namespace
    labels = local.common_labels
  }
}

resource "kubernetes_config_map_v1" "orders" {
  metadata {
    name      = "orders-config"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = local.common_labels
  }

  data = {
    PG_HOST            = kubernetes_service_v1.postgres.metadata[0].name
    PG_PORT            = "5432"
    PG_DB              = "orders"
    PG_USER            = "orders"
    REDIS_HOST         = kubernetes_service_v1.redis.metadata[0].name
    REDIS_PORT         = "6379"
    CACHE_TTL_SECONDS  = "60"
    PRICING_ITERATIONS = tostring(var.pricing_iterations)
    WORKER_WORK_MS     = tostring(var.worker_work_ms)
    APP_VERSION        = local.image_tag
  }
}

resource "kubernetes_secret_v1" "orders" {
  metadata {
    name      = "orders-secrets"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = local.common_labels
  }

  type = "Opaque"
  data = {
    PG_PASSWORD    = local.platform.postgres_password
    REDIS_PASSWORD = local.platform.redis_password
  }
}

# ------------------------------------------------- data tier (outside cluster)
# Selector-less Services + EndpointSlices give pods stable in-cluster DNS names
# (postgres.orders.svc, redis.orders.svc) for the Docker-hosted databases. The IPs
# come from stage-1 outputs, never hardcoded.

resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_endpoint_slice_v1" "postgres" {
  metadata {
    name      = "postgres-external"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels = merge(local.common_labels, {
      "kubernetes.io/service-name"             = kubernetes_service_v1.postgres.metadata[0].name
      "endpointslice.kubernetes.io/managed-by" = "terraform"
    })
  }
  address_type = "IPv4"
  endpoint {
    addresses = [local.platform.postgres_ip]
    condition {
      ready = true
    }
  }
  port {
    name         = "postgres"
    port         = "5432"
    protocol     = "TCP"
    app_protocol = "postgresql"
  }
}

resource "kubernetes_service_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = local.common_labels
  }
  spec {
    port {
      name        = "redis"
      port        = 6379
      target_port = 6379
    }
  }
}

resource "kubernetes_endpoint_slice_v1" "redis" {
  metadata {
    name      = "redis-external"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels = merge(local.common_labels, {
      "kubernetes.io/service-name"             = kubernetes_service_v1.redis.metadata[0].name
      "endpointslice.kubernetes.io/managed-by" = "terraform"
    })
  }
  address_type = "IPv4"
  endpoint {
    addresses = [local.platform.redis_ip]
    condition {
      ready = true
    }
  }
  port {
    name         = "redis"
    port         = "6379"
    protocol     = "TCP"
    app_protocol = "redis"
  }
}

# ---------------------------------------------------------- schema migration
# A new Job per image tag runs `alembic upgrade head` before the API rolls out.

resource "kubernetes_job_v1" "migrate" {
  metadata {
    name      = "orders-migrate-${substr(sha1(var.image), 0, 8)}"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = merge(local.common_labels, { "app.kubernetes.io/name" = "orders-migrate" })
  }

  spec {
    backoff_limit = 4
    template {
      metadata {
        labels = merge(local.common_labels, { "app.kubernetes.io/name" = "orders-migrate" })
      }
      spec {
        restart_policy = "Never"
        container {
          name              = "migrate"
          image             = var.image
          image_pull_policy = "Never"
          command           = ["python", "-m", "orders.migrate"]
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.orders.metadata[0].name
            }
          }
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.orders.metadata[0].name
            }
          }
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "5m"
    update = "5m"
  }

  depends_on = [
    terraform_data.image_load,
    kubernetes_endpoint_slice_v1.postgres,
  ]
}
