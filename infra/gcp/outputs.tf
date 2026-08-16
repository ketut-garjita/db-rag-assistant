output "app_url" {
  description = "Public URL of the DB Schema & Query Assistant"
  value       = google_cloud_run_v2_service.app.uri
}

output "monitoring_url" {
  description = "Public URL of the monitoring dashboard"
  value       = google_cloud_run_v2_service.monitoring.uri
}

output "cloud_sql_connection_name" {
  description = "Use with `gcloud sql connect` or the Cloud SQL Auth Proxy for direct psql access (e.g. to run db/schema.sql once)"
  value       = google_sql_database_instance.postgres.connection_name
}

output "artifact_registry_repo" {
  description = "Push images here: <region>-docker.pkg.dev/<project_id>/db-rag-assistant/<name>:<tag>"
  value       = google_artifact_registry_repository.repo.name
}
