# --- CI/CD identity: the service account Cloud Build runs as ------------------
# Only the roles the pipeline needs: push images, deploy Cloud Run, act as the
# runtime SA, and write build logs. No Owner/Editor.

resource "google_service_account" "deployer" {
  account_id   = "${var.app_name}-deployer"
  display_name = "LinkPulse Cloud Build deployer"
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/run.developer",
    "roles/artifactregistry.writer",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Deploying a Cloud Run service "as" the runtime SA needs actAs on that SA only
resource "google_service_account_iam_member" "deployer_act_as_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.deployer.email}"
}

# --- Trigger: run cloudbuild.yaml on every push to main -----------------------
# Needs the GitHub repo connected to Cloud Build once (console, 2nd-gen connection).

resource "google_cloudbuild_trigger" "main" {
  count = var.github_repo_resource == "" ? 0 : 1

  name            = "${var.app_name}-main"
  location        = var.region
  filename        = "cloudbuild.yaml"
  service_account = google_service_account.deployer.id

  repository_event_config {
    repository = var.github_repo_resource
    push { branch = "^main$" }
  }

  depends_on = [google_project_iam_member.deployer]
}
