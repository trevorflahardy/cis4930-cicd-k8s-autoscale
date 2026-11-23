# Stage 2: cluster add-ons installed with Helm.
#   * metrics-server: CPU/memory metrics for the HorizontalPodAutoscaler
#   * KEDA: event-driven autoscaling (scales the worker on Redis queue depth)
# Split from stage 3 so KEDA's CRDs exist before any ScaledObject is planned.

terraform {
  required_version = ">= 1.6"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
  }
}

data "terraform_remote_state" "platform" {
  backend = "local"
  config = {
    path = "${path.module}/../01-platform/terraform.tfstate"
  }
}

locals {
  platform = data.terraform_remote_state.platform.outputs
}

provider "helm" {
  kubernetes = {
    host                   = local.platform.endpoint
    client_certificate     = local.platform.client_certificate
    client_key             = local.platform.client_key
    cluster_ca_certificate = local.platform.cluster_ca_certificate
  }
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    args = [
      # kind kubelets use self-signed serving certs.
      "--kubelet-insecure-tls",
      "--metric-resolution=15s",
    ]
  })]
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 600
}
