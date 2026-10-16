locals {
  # Cloud Run needs *some* image on first create. CI/CD replaces it on every deploy.
  bootstrap_image = "us-docker.pkg.dev/cloudrun/container/hello"
  registry_url    = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.app.repository_id}"
}

# --- APIs ---------------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "firestore.googleapis.com",
    "cloudbuild.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# --- Artifact Registry: where CI pushes Docker images -------------------------

resource "google_artifact_registry_repository" "app" {
  repository_id = var.app_name
  location      = var.region
  format        = "DOCKER"
  description   = "LinkPulse container images"

  # Auto-clean old images so storage cost stays near zero
  cleanup_policies {
    id     = "keep-last-10"
    action = "KEEP"
    most_recent_versions { keep_count = 10 }
  }
  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"
    condition { older_than = "2592000s" } # 30 days
  }

  depends_on = [google_project_service.apis]
}

# --- Firestore: the database (one DB, one collection per environment) --------

resource "google_firestore_database" "default" {
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  depends_on = [google_project_service.apis]
}

# --- Runtime identity: least-privilege service account for the app ----------

resource "google_service_account" "runtime" {
  account_id   = "${var.app_name}-runtime"
  display_name = "LinkPulse Cloud Run runtime"
}

resource "google_project_iam_member" "runtime_firestore" {
  project = var.project_id
  role    = "roles/datastore.user" # read/write Firestore docs, nothing else
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# --- Cloud Run: one service per environment ----------------------------------

resource "google_cloud_run_v2_service" "app" {
  for_each = var.environments

  name                = "${var.app_name}-${each.key}"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = each.value.min_instances # 0 = scale to zero, no idle cost
      max_instance_count = each.value.max_instances
    }

    containers {
      image = local.bootstrap_image

      resources {
        limits            = { cpu = "1", memory = "512Mi" }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      env {
        name  = "ENVIRONMENT"
        value = each.key
      }
      env {
        name  = "STORAGE_BACKEND"
        value = "firestore"
      }
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }

      startup_probe {
        http_get { path = "/healthz" }
      }
      liveness_probe {
        http_get { path = "/healthz" }
      }
    }
  }

  lifecycle {
    # CI/CD owns the image + version label; Terraform owns everything else.
    # Without this, every `terraform apply` would roll the app back to the bootstrap image.
    ignore_changes = [
      template[0].containers[0].image,
      template[0].containers[0].env,
      template[0].labels,
      client,
      client_version,
    ]
  }

  depends_on = [google_project_service.apis, google_project_iam_member.runtime_firestore]
}

# Public URL shortener -> anyone can invoke it
resource "google_cloud_run_v2_service_iam_member" "public" {
  for_each = google_cloud_run_v2_service.app

  name     = each.value.name
  location = each.value.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
