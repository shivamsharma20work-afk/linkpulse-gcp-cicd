output "registry_url" {
  description = "Push images here: <registry_url>/app:<tag>"
  value       = local.registry_url
}

output "service_urls" {
  value = { for env, svc in google_cloud_run_v2_service.app : env => svc.uri }
}

output "runtime_service_account" {
  value = google_service_account.runtime.email
}
