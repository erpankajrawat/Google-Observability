# terraform/observability-project/variables.tf
variable "billing_account_id" {
  description = "GCP Billing Account ID"
  type        = string
}

variable "org_id" {
  description = "GCP Organization ID"
  type        = string
}

variable "folder_id" {
  description = "GCP Folder ID (optional)"
  type        = string
  default     = null
}