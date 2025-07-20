# terraform/observability-project/main.tf
# ===============================================
# Central Observability Project Infrastructure
# ===============================================

locals {
  project_name = "observability-stack-1on1"
  region       = "australia-southeast2"
  zone         = "australia-southeast2-a"

  labels = {
    environment         = "production"
    purpose             = "observability"
    cost-center         = "platform-engineering"
    data-classification = "internal"
  }
}

# Create the observability project
resource "google_project" "observability" {
  name            = "Central Observability Platform"
  project_id      = "anz-central-obs-${random_string.project_suffix.result}"
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
    "bigquery.googleapis.com",
    "pubsub.googleapis.com",
    "dataflow.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudkms.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com"
  ])

  project = google_project.observability.project_id
  service = each.key

  disable_on_destroy = false
}

# KMS key for encryption
resource "google_kms_key_ring" "observability" {
  name     = "observability-keyring"
  location = local.region
  project  = google_project.observability.project_id

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "observability" {
  name     = "observability-key"
  key_ring = google_kms_key_ring.observability.id

  lifecycle {
    prevent_destroy = true
  }
}

# BigQuery dataset for logs
resource "google_bigquery_dataset" "logs" {
  dataset_id    = "central_logs"
  friendly_name = "Central Log Dataset"
  description   = "Centralized logs from all workload projects"
  location      = local.region
  project       = google_project.observability.project_id

  default_table_expiration_ms     = 2592000000 # 30 days
  default_partition_expiration_ms = 7776000000 # 90 days

  labels = local.labels

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.observability.id
  }

  depends_on = [google_project_service.apis]
}

# Create sharded tables for high throughput
resource "google_bigquery_table" "log_shards" {
  count = 4

  dataset_id = google_bigquery_dataset.logs.dataset_id
  table_id   = "real_time_logs_shard_${count.index + 1}"
  project    = google_project.observability.project_id

  time_partitioning {
    type  = "DAY"
    field = "timestamp"
  }

  clustering = ["severity", "resource_type", "project_id"]

  schema = jsonencode([
    {
      name = "timestamp"
      type = "TIMESTAMP"
      mode = "REQUIRED"
    },
    {
      name = "severity"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "message"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "resource_type"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "project_id"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "trace_id"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "span_id"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "labels"
      type = "JSON"
      mode = "NULLABLE"
    },
    {
      name = "resource_name"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "source_location"
      type = "JSON"
      mode = "NULLABLE"
    }
  ])

  labels = local.labels
}

# Pub/Sub topic for log ingestion
resource "google_pubsub_topic" "logs" {
  name    = "central-logs-topic"
  project = google_project.observability.project_id

  labels = local.labels

  message_storage_policy {
    allowed_persistence_regions = [local.region]
  }

  depends_on = [google_project_service.apis]
}

# Pub/Sub subscription for Dataflow
resource "google_pubsub_subscription" "logs" {
  name    = "central-logs-subscription"
  topic   = google_pubsub_topic.logs.name
  project = google_project.observability.project_id

  ack_deadline_seconds = 600

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  labels = local.labels
}

# Cloud Storage bucket for Dataflow staging
resource "google_storage_bucket" "dataflow_staging" {
  name     = "dataflow-staging-${google_project.observability.project_id}"
  location = local.region
  project  = google_project.observability.project_id

  uniform_bucket_level_access = true

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.observability.id
  }

  labels = local.labels
}

# Service account for Dataflow
resource "google_service_account" "dataflow" {
  account_id   = "dataflow-processor"
  display_name = "Dataflow Log Processor"
  project      = google_project.observability.project_id
}

# IAM permissions for Dataflow service account
resource "google_project_iam_member" "dataflow_permissions" {
  for_each = toset([
    "roles/bigquery.dataEditor",
    "roles/pubsub.subscriber",
    "roles/storage.objectAdmin",
    "roles/dataflow.worker"
  ])

  project = google_project.observability.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.dataflow.email}"
}

# Cloud Run service for log generator (testing)
resource "google_cloud_run_service" "log_generator" {
  name     = "log-generator"
  project  = google_project.observability.project_id
  location = local.region

  template {
    spec {
      containers {
        image = "gcr.io/${google_project.observability.project_id}/log-generator:latest"

        env {
          name  = "PUBSUB_TOPIC"
          value = google_pubsub_topic.logs.id
        }

        env {
          name  = "PROJECT_ID"
          value = google_project.observability.project_id
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

# Monitoring alert policy for high error rates
resource "google_monitoring_alert_policy" "high_error_rate" {
  display_name = "High Error Rate in Logs"
  project      = google_project.observability.project_id

  combiner = "OR"

  conditions {
    display_name = "Error rate > 10%"

    condition_threshold {
      filter          = "resource.type=\"pubsub_topic\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.1
    }
  }

  notification_channels = []

  alert_strategy {
    auto_close = "1800s"
  }

  depends_on = [google_project_service.apis]
}