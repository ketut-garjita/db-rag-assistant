# =============================================================================
# db-rag-assistant on GCP — Cloud Run (app + monitoring) + Cloud SQL (pgvector)
#
# Mirrors docker-compose.yml's `db`, `app`, and `monitoring` services.
# `ollama`/`pgadmin`/`kestra` are intentionally NOT reproduced here — see
# the README "Cloud deployment" section for why (Ollama needs a GPU VM,
# pgAdmin/Kestra are local dev tools you're unlikely to want publicly
# exposed). NOT YET APPLIED/TESTED against a real GCP project — review
# every resource before running `terraform apply`.
# =============================================================================

# --- Required APIs -----------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# --- Artifact Registry (holds the app/monitoring image) ----------------
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "db-rag-assistant"
  format        = "DOCKER"
  depends_on    = [google_project_service.apis]
}

# --- Cloud SQL (Postgres + pgvector) ------------------------------------
# pgvector is supported on Cloud SQL for PostgreSQL 15+; the extension
# itself still needs `CREATE EXTENSION vector;` run against the database
# once (see README -- this isn't automated by Terraform since it requires
# a live DB connection, not just API calls).
resource "google_sql_database_instance" "postgres" {
  name             = "db-rag-postgres"
  database_version = "POSTGRES_15"
  region           = var.region

  settings {
    tier = var.cloud_sql_tier

    ip_configuration {
      ipv4_enabled = true
      # Cloud Run connects via the Cloud SQL connector (see the `volumes`
      # block on each service below), not over this public IP -- this
      # flag mainly affects whether you can `psql` in directly for setup.
    }

    backup_configuration {
      enabled = true
    }
  }

  deletion_protection = false # flip to true once this holds real data

  depends_on = [google_project_service.apis]
}

# NOTE: no google_sql_database resource here on purpose. Cloud SQL for
# PostgreSQL always auto-creates a database named "postgres" the moment
# the instance is provisioned (standard Postgres behavior) -- trying to
# `create` a database with that same name via Terraform fails with
# "database already exists". Since our app already uses PG_DB=postgres
# everywhere (matching docker-compose.yml's default), we just reference
# that pre-existing default database by name instead of managing it as
# a separate resource.
locals {
  app_db_name = "postgres"
}

resource "google_sql_user" "app_user" {
  name     = "postgres"
  instance = google_sql_database_instance.postgres.name
  password = var.db_password
}

# --- Secrets -------------------------------------------------------------
resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-rag-db-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret" "openai_api_key" {
  secret_id = "db-rag-openai-api-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "openai_api_key" {
  secret      = google_secret_manager_secret.openai_api_key.id
  secret_data = var.openai_api_key
}

# --- Service account for Cloud Run (least-privilege, not the default) --
resource "google_service_account" "cloud_run_sa" {
  account_id   = "db-rag-cloud-run"
  display_name = "db-rag-assistant Cloud Run service account"
}

resource "google_project_iam_member" "cloud_run_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "db_password_access" {
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "openai_key_access" {
  secret_id = google_secret_manager_secret.openai_api_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.cloud_run_sa.email}"
}

# --- Cloud Run: main app (Streamlit — Schema QA + NL2SQL UI) -----------
resource "google_cloud_run_v2_service" "app" {
  name     = "db-rag-app"
  location = var.region

  template {
    service_account = google_service_account.cloud_run_sa.email

    # Optional, not enabled by default (costs money -- keeps at least one
    # instance warm at all times instead of scaling to zero). Uncomment
    # if startup_cpu_boost below still isn't enough and every first-click
    # after idle time is unacceptably slow:
    # scaling {
    #   min_instance_count = 1
    #   max_instance_count = 3
    # }

    containers {
      image = var.app_image_tag

      ports {
        container_port = 8501
      }

      env {
        name  = "PG_HOST"
        value = "/cloudsql/${google_sql_database_instance.postgres.connection_name}"
      }
      env {
        name  = "PG_PORT"
        value = "5432"
      }
      env {
        name  = "PG_DB"
        value = local.app_db_name
      }
      env {
        name  = "PG_USER"
        value = google_sql_user.app_user.name
      }
      env {
        name = "PG_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "OPENAI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.openai_api_key.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "LLM_MODEL"
        value = var.llm_model
      }
			env {
        name  = "OPENAI_BASE_URL"
        value = var.openai_base_url
      }
      
      resources {
        limits = {
          cpu    = "2"
          memory = "2Gi"
        }
        # Cloud Run's default is CPU allocated only during request
        # processing, throttled the rest of the time -- fine for most
        # apps, but this service imports a heavy ML stack
        # (sentence_transformers -> torch -> transformers -> sklearn)
        # lazily on first real use, and a throttled/cold CPU makes that
        # import take even longer. startup_cpu_boost gives extra CPU
        # specifically during container startup to help with this.
        startup_cpu_boost = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }

    # Default is 300s -- the first request that triggers the heavy
    # sentence_transformers/torch import chain (embedding + re-ranking
    # models) can take a while on a cold instance; give it more room
    # than the default so Cloud Run doesn't kill the request mid-import.
    timeout = "600s"

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.postgres.connection_name]
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_service_iam_member" "app_public" {
  count    = var.allow_public_access ? 1 : 0
  name     = google_cloud_run_v2_service.app.name
  location = google_cloud_run_v2_service.app.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# --- Cloud Run: monitoring dashboard ------------------------------------
# Same image as `app`, just overrides the container command like the
# `monitoring` service does in docker-compose.yml.
resource "google_cloud_run_v2_service" "monitoring" {
  name     = "db-rag-monitoring"
  location = var.region

  template {
    service_account = google_service_account.cloud_run_sa.email

    containers {
      image   = var.app_image_tag
      command = ["streamlit", "run", "rag/monitoring/monitoring_dashboard.py"]
      args    = ["--server.address=0.0.0.0", "--server.port=8502"]

      ports {
        container_port = 8502
      }

      env {
        name  = "PG_HOST"
        value = "/cloudsql/${google_sql_database_instance.postgres.connection_name}"
      }
      env {
        name  = "PG_PORT"
        value = "5432"
      }
      env {
        name  = "PG_DB"
        value = local.app_db_name
      }
      env {
        name  = "PG_USER"
        value = google_sql_user.app_user.name
      }
      env {
        name = "PG_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.postgres.connection_name]
      }
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_cloud_run_v2_service_iam_member" "monitoring_public" {
  count    = var.allow_public_access ? 1 : 0
  name     = google_cloud_run_v2_service.monitoring.name
  location = google_cloud_run_v2_service.monitoring.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}
