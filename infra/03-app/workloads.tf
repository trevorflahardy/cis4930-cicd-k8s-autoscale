# ----------------------------------------------------------------------- API

resource "kubernetes_deployment_v1" "api" {
  metadata {
    name      = "orders-api"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = merge(local.common_labels, local.api_labels)
  }

  spec {
    # Replica count is owned by the HPA after the first apply.
    replicas = var.api_min_replicas

    selector {
      match_labels = local.api_labels
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    template {
      metadata {
        labels = merge(local.common_labels, local.api_labels)
      }

      spec {
        termination_grace_period_seconds = 20

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = local.api_labels
          }
        }

        container {
          name              = "api"
          image             = var.image
          image_pull_policy = "Never"

          port {
            name           = "http"
            container_port = 8000
          }

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

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/ready"
              port = "http"
            }
            period_seconds    = 5
            timeout_seconds   = 3
            failure_threshold = 3
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
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

  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  depends_on = [kubernetes_job_v1.migrate]
}

resource "kubernetes_service_v1" "api" {
  metadata {
    name      = "orders-api"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = merge(local.common_labels, local.api_labels)
  }

  spec {
    type     = "NodePort"
    selector = local.api_labels
    port {
      name        = "http"
      port        = 80
      target_port = "http"
      node_port   = local.platform.api_node_port
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "api" {
  metadata {
    name      = "orders-api"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = merge(local.common_labels, local.api_labels)
  }
  spec {
    min_available = "1"
    selector {
      match_labels = local.api_labels
    }
  }
}

# -------------------------------------------------------------------- worker

resource "kubernetes_deployment_v1" "worker" {
  metadata {
    name      = "orders-worker"
    namespace = kubernetes_namespace_v1.orders.metadata[0].name
    labels    = merge(local.common_labels, local.worker_labels)
  }

  spec {
    # Replica count is owned by KEDA after the first apply.
    replicas = var.worker_min_replicas

    selector {
      match_labels = local.worker_labels
    }

    template {
      metadata {
        labels = merge(local.common_labels, local.worker_labels)
      }

      spec {
        termination_grace_period_seconds = 15

        container {
          name              = "worker"
          image             = var.image
          image_pull_policy = "Never"
          command           = ["python", "-m", "orders.worker"]

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

          resources {
            requests = {
              cpu    = "50m"
              memory = "96Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "192Mi"
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

  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  depends_on = [kubernetes_job_v1.migrate]
}
