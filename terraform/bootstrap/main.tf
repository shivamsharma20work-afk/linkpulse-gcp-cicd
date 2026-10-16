# One-time bootstrap: creates the GCS bucket that stores Terraform state
# for the main config. This folder itself uses local state (chicken-and-egg).
#
#   cd terraform/bootstrap
#   terraform init && terraform apply -var project_id=<YOUR_PROJECT>

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "asia-south1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "tf_state" {
  name                        = "${var.project_id}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Keep old state versions so a bad apply can be rolled back
  versioning { enabled = true }
  lifecycle_rule {
    condition { num_newer_versions = 10 }
    action { type = "Delete" }
  }
}

output "state_bucket" { value = google_storage_bucket.tf_state.name }
