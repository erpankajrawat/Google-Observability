

```markdown
# Google Centralized Log Aggregation & Observability Platform on GCP (Terraform)

This solution provisions a centralized log aggregation and observability platform on Google Cloud Platform using Terraform. It enables real-time log processing, intelligent storage management, and comprehensive monitoring across multiple GCP projects.

---

## Directory Structure

```
.
├── main.tf
├── variables.tf
├── outputs.tf
├── providers.tf
├── modules/
│   ├── log_sink/
│   ├── storage/
│   └── monitoring/
└── README.md
```

---

## main.tf

```hcl
provider "google" {
    project = var.central_project_id
    region  = var.region
}

module "log_sink" {
    source             = "./modules/log_sink"
    central_project_id = var.central_project_id
    source_projects    = var.source_projects
    sink_bucket_name   = module.storage.bucket_name
}

module "storage" {
    source             = "./modules/storage"
    bucket_name        = var.sink_bucket_name
    location           = var.region
    retention_days     = var.retention_days
}

module "monitoring" {
    source             = "./modules/monitoring"
    central_project_id = var.central_project_id
}
```

---

## variables.tf

```hcl
variable "central_project_id" {
    description = "GCP project for centralized logging"
    type        = string
}

variable "source_projects" {
    description = "List of GCP projects to aggregate logs from"
    type        = list(string)
}

variable "region" {
    description = "GCP region"
    type        = string
    default     = "us-central1"
}

variable "sink_bucket_name" {
    description = "Name for the log sink storage bucket"
    type        = string
}

variable "retention_days" {
    description = "Log retention period in days"
    type        = number
    default     = 30
}
```

---

## outputs.tf

```hcl
output "log_sink_bucket" {
    value = module.storage.bucket_name
}

output "monitoring_dashboard_url" {
    value = module.monitoring.dashboard_url
}
```

---

## modules/log_sink/main.tf

```hcl
resource "google_logging_project_sink" "central_sink" {
    for_each        = toset(var.source_projects)
    name            = "central-log-sink"
    destination     = "storage.googleapis.com/${var.sink_bucket_name}"
    project         = each.key
    filter          = ""
    unique_writer_identity = true
}
```

---

## modules/storage/main.tf

```hcl
resource "google_storage_bucket" "log_bucket" {
    name          = var.bucket_name
    location      = var.location
    force_destroy = true

    lifecycle_rule {
        action {
            type = "Delete"
        }
        condition {
            age = var.retention_days
        }
    }
}

output "bucket_name" {
    value = google_storage_bucket.log_bucket.name
}
```

---

## modules/monitoring/main.tf

```hcl
resource "google_monitoring_dashboard" "log_dashboard" {
    project = var.central_project_id
    dashboard_json = file("${path.module}/dashboard.json")
}

output "dashboard_url" {
    value = "https://console.cloud.google.com/monitoring/dashboards/custom/${google_monitoring_dashboard.log_dashboard.dashboard_id}?project=${var.central_project_id}"
}
```

---

## modules/monitoring/dashboard.json

```json
{
    "displayName": "Centralized Log Monitoring",
    "widgets": [
        {
            "title": "Log Entries Over Time",
            "xyChart": {
                "dataSets": [
                    {
                        "timeSeriesQuery": {
                            "timeSeriesFilter": {
                                "filter": "resource.type=\"gcs_bucket\" metric.type=\"logging.googleapis.com/log_entry_count\""
                            }
                        }
                    }
                ]
            }
        }
    ]
}
```

---

## Usage

1. Fill in `terraform.tfvars` with your project IDs and settings.
2. Run `terraform init && terraform apply`.
3. Access the monitoring dashboard via the output URL.

---
```