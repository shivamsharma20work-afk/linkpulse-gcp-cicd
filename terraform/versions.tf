terraform {
  required_version = ">= 1.9"

  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }

  # Remote state in GCS (bucket created by ./bootstrap). Bucket name is passed at init:
  #   terraform init -backend-config="bucket=<PROJECT_ID>-tfstate"
  backend "gcs" {
    prefix = "linkpulse"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
