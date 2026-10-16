# LinkPulse: CI/CD Platform on GCP

A URL shortener with click analytics, used as the workload for a production-style
delivery platform on Google Cloud: **Terraform** for infrastructure, **Cloud Build**
for CI/CD, **Cloud Run** for compute, **Firestore** for data, and **Cloud Monitoring**
for uptime checks, SLOs and alerts.

```
 git push main
      │
      ▼
 ┌──────────────────────── Cloud Build (cloudbuild.yaml) ────────────────────────┐
 │ pytest + ruff ─► docker build ─► Trivy scan ─► push to Artifact Registry      │
 │      ─► deploy staging ─► smoke test                                          │
 │      ─► prod canary (0% → smoke → 10% → watch) ─► promote 100%                │
 │                                   └── any failure ─► rollback to last revision│
 └───────────────────────────────────────────────────────────────────────────────┘
      │                                   │
      ▼                                   ▼
 Cloud Run: linkpulse-staging        Cloud Run: linkpulse-prod
      └────────────── Firestore (links_staging / links_prod) ──┘
                         │
        Uptime checks · SLO 99.5% · burn-rate alerts · dashboard
```

## What's in here

| Path | What it does |
|---|---|
| `src/linkpulse/` | FastAPI app: create short links, redirect, count clicks. Storage is an interface with in-memory (local/tests) and Firestore (cloud) implementations |
| `Dockerfile` | Multi-stage build with `uv`; runtime image has only the venv and runs as non-root UID 10001 |
| `cloudbuild.yaml` | The pipeline: tests, lint, build, Trivy scan, staging deploy, smoke test, canary to prod |
| `scripts/smoke_test.sh` | Health, version check, and a real create + redirect against a deployed URL |
| `scripts/canary_deploy.sh` | Zero-traffic deploy with a `canary` tag, smoke test, 10% split, health watch, then promote or roll back |
| `terraform/bootstrap/` | One-time: versioned GCS bucket for remote Terraform state |
| `terraform/main.tf` | APIs, Artifact Registry (with cleanup policy), Firestore, runtime SA, staging + prod Cloud Run |
| `terraform/cicd.tf` | Least-privilege deployer SA for Cloud Build and the push-to-main trigger |
| `terraform/monitoring.tf` | Uptime checks, uptime alerts, request-based availability SLO, burn-rate alert, dashboard |

## Design decisions

- **Terraform owns infra, CI owns the image.** Cloud Run's image and env are in `ignore_changes`,
  so a `terraform apply` never rolls the app back to an old image.
- **Least privilege.** The runtime SA only has `roles/datastore.user`. The deployer SA has
  `run.developer`, `artifactregistry.writer`, `logging.logWriter`, and `actAs` on the runtime SA
  only. Neither has Editor or Owner.
- **Canary with automatic rollback.** The new revision gets 0% traffic first and is smoke-tested
  through its private tag URL. Real users see it only after that passes. If anything fails, traffic
  goes back 100% to the revision that was serving before the deploy.
- **Scale to zero.** `min_instances = 0` and an Artifact Registry cleanup policy keep idle cost
  close to nothing.
- **State safety.** Remote state lives in a versioned GCS bucket with public access prevention,
  so a bad apply can be recovered from an older state version.

## Run locally

```bash
uv sync
uv run uvicorn linkpulse.main:app --reload --port 8080
uv run pytest -q && uv run ruff check .
```

Or in Docker:

```bash
docker build -t linkpulse . && docker run -p 8080:8080 linkpulse
./scripts/smoke_test.sh http://localhost:8080
```

## Deploy to GCP

```bash
# 1. State bucket (once)
cd terraform/bootstrap && terraform init && terraform apply -var project_id=$PROJECT

# 2. Platform
cd .. && cp terraform.tfvars.example terraform.tfvars   # set project_id, alert_email
terraform init -backend-config="bucket=$PROJECT-tfstate"
terraform apply

# 3. Connect this GitHub repo to Cloud Build (2nd-gen connection) once in the console,
#    set github_repo_resource in terraform.tfvars, apply again. Every push to main now deploys.
```

Manual pipeline run without a trigger:

```bash
gcloud builds submit --config cloudbuild.yaml --substitutions=SHORT_SHA=$(git rev-parse --short HEAD)
```
