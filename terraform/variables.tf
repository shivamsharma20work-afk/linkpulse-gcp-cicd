variable "project_id" {
  description = "GCP project to deploy into"
  type        = string
}

variable "region" {
  description = "Region for Cloud Run, Artifact Registry and Firestore"
  type        = string
  default     = "asia-south1" # Mumbai
}

variable "app_name" {
  type    = string
  default = "linkpulse"
}

variable "environments" {
  description = "One Cloud Run service per environment"
  type = map(object({
    min_instances = number
    max_instances = number
  }))
  default = {
    staging = { min_instances = 0, max_instances = 2 }
    prod    = { min_instances = 0, max_instances = 5 }
  }
}

variable "alert_email" {
  description = "Where uptime/SLO alerts go. Empty = no notification channel."
  type        = string
  default     = ""
}

variable "github_repo_resource" {
  description = "Cloud Build 2nd-gen repo id: projects/<p>/locations/<r>/connections/<c>/repositories/<repo>. Empty = no trigger."
  type        = string
  default     = ""
}
