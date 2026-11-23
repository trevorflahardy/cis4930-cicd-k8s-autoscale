# API: classic HPA on CPU. Each POST /orders burns CPU (PBKDF2 pricing), so client
# request volume becomes CPU pressure and the HPA adds pods.

resource "kubernetes_horizontal_pod_autoscaler_v2" "api" {
  metadata {
    name      = "orders-api"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = merge(local.common_labels, local.api_labels)
  }

  spec {
    min_replicas = var.api_min_replicas
    max_replicas = var.api_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.api.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.api_cpu_target_percent
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 60
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 15
        }
      }
    }
  }
}

# Worker: KEDA scales on the Redis list length (orders waiting to be processed).

resource "kubernetes_manifest" "redis_trigger_auth" {
  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata = {
      name      = "orders-redis-auth"
      namespace = kubernetes_namespace_v1.orders.metadata[0].name
    }
    spec = {
      secretTargetRef = [{
        parameter = "password"
        name      = kubernetes_secret_v1.orders.metadata[0].name
        key       = "REDIS_PASSWORD"
      }]
    }
  }
}

resource "kubernetes_manifest" "worker_scaledobject" {
  manifest = {
    apiVersion = "keda.sh/v1alpha1"
    kind       = "ScaledObject"
    metadata = {
      name      = "orders-worker"
      namespace = kubernetes_namespace_v1.orders.metadata[0].name
    }
    spec = {
      scaleTargetRef = {
        name = kubernetes_deployment_v1.worker.metadata[0].name
      }
      minReplicaCount = var.worker_min_replicas
      maxReplicaCount = var.worker_max_replicas
      cooldownPeriod  = 30
      advanced = {
        horizontalPodAutoscalerConfig = {
          behavior = {
            scaleDown = {
              stabilizationWindowSeconds = 60
            }
          }
        }
      }
      triggers = [{
        type = "redis"
        metadata = {
          address    = "${kubernetes_service_v1.redis.metadata[0].name}.${var.namespace}.svc.cluster.local:6379"
          listName   = "orders:queue"
          listLength = tostring(var.worker_queue_target)
        }
        authenticationRef = {
          name = kubernetes_manifest.redis_trigger_auth.manifest.metadata.name
        }
      }]
    }
  }
}
