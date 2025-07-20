# terraform/workload-project/main.tf
# ==========================================
# Sample Workload Project Infrastructure
# ==========================================

locals {
  project_name = "sample-workload"
  region       = "australia-southeast2"
  zone         = "australia-southeast2-a"
  
  labels = {
    environment = "development"
    purpose     = "sample-application"
    cost-center = "development"
  }
}

# Create workload project
resource "google_project" "workload" {
  name            = "Sample Workload Project"
  project_id      = "anz-workload-${random_string.project_suffix.result}"
  billing_account = var.billing_account_id
  
  labels = local.labels
}

resource "random_string" "project_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Enable required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com"
  ])
  
  project = google_project.workload.project_id
  service = each.key
  
  disable_on_destroy = false
}

# GKE cluster for sample applications
resource "google_container_cluster" "sample_cluster" {
  name     = "sample-cluster"
  location = local.zone
  project  = google_project.workload.project_id
  
  initial_node_count       = 1
  remove_default_node_pool = true
  
  network    = "default"
  subnetwork = "default"
  
  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "sample_nodes" {
  name       = "sample-node-pool"
  location   = local.zone
  cluster    = google_container_cluster.sample_cluster.name
  project    = google_project.workload.project_id
  node_count = 2
  
  node_config {
    preemptible  = true
    machine_type = "e2-medium"
    
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    
    labels = local.labels
  }
}

# Service account for log forwarding
resource "google_service_account" "log_forwarder" {
  account_id   = "log-forwarder"
  display_name = "Log Forwarder Service Account"
  project      = google_project.workload.project_id
}

# IAM permission to publish to central observability topic
resource "google_pubsub_topic_iam_member" "log_publisher" {
  project = var.central_observability_project_id
  topic   = var.central_logs_topic_name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.log_forwarder.email}"
}

# Cloud Run service for sample application
resource "google_cloud_run_service" "sample_app" {
  name     = "sample-application"
  project  = google_project.workload.project_id
  location = local.region
  
  template {
    spec {
      containers {
        image = "gcr.io/${google_project.workload.project_id}/sample-app:latest"
        
        env {
          name  = "LOG_LEVEL"
          value = "INFO"
        }
        
        resources {
          limits = {
            cpu    = "1000m"
            memory = "512Mi"
          }
        }
      }
    }
  }
  
  traffic {
    percent         = 100
    latest_revision = true
  }
  
  depends_on = [google_project_service.apis]
}

# Log sink to forward logs to central observability
resource "google_logging_project_sink" "central_logs" {
  name        = "central-observability-sink"
  project     = google_project.workload.project_id
  destination = "pubsub.googleapis.com/projects/${var.central_observability_project_id}/topics/${var.central_logs_topic_name}"
  
  filter = "severity >= WARNING OR resource.type=\"k8s_container\" OR resource.type=\"cloud_run_revision\""
  
  unique_writer_identity = true
}

# Grant sink writer permission to publish to Pub/Sub
resource "google_pubsub_topic_iam_member" "sink_publisher" {
  project = var.central_observability_project_id
  topic   = var.central_logs_topic_name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.central_logs.writer_identity
}