terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure to keep state somewhere shared/durable instead
  # of a local .tfstate file (recommended once more than one person, or
  # more than one machine, touches this infra):
  #
  # backend "gcs" {
  #   bucket = "your-terraform-state-bucket"
  #   prefix = "db-rag-assistant"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
