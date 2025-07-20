# terraform/observability-project/outputs.tf
output "observability_project_id" {
  description = "Central observability project ID"
  value       = google_project.observability.project_id
}

output "pubsub_topic" {
  description = "Pub/Sub topic for log ingestion"
  value       = google_pubsub_topic.logs.id
}

output "bigquery_dataset" {
  description = "BigQuery dataset for logs"
  value       = google_bigquery_dataset.logs.dataset_id
}

output "dataflow_service_account" {
  description = "Service account for Dataflow"
  value       = google_service_account.dataflow.email
}

output "staging_bucket" {
  description = "GCS bucket for Dataflow staging"
  value       = google_storage_bucket.dataflow_staging.name
}