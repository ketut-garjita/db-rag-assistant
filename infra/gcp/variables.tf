variable "project_id" {
  description = "db-rag-assistant"
  type        = string
}

variable "region" {
  description = "asia-southeast2"
  type        = string
  default     = "asia-southeast2"
}

variable "db_password" {
  description = "postgres"
  type        = string
  sensitive   = true
}

variable "openai_api_key" {
  description = <<-EOT
    API key for the LLM provider. Use a real OpenAI (or other hosted,
    OpenAI-compatible) API key here -- Ollama is not practical on
    serverless Cloud Run (no GPU by default, cold starts kill any
    locally-cached model, no persistent disk for model weights). See
    the README section "Cloud deployment" for a Compute Engine
    alternative if you want to keep self-hosting the LLM.
  EOT
  type        = string
  sensitive   = true
}

variable "llm_model" {
  description = "Model name to request from the LLM provider in this deployment"
  type        = string
  default     = "qwen/qwen3.6-27b"
}

variable "openai_base_url" {
  description = "openai_base_url to request from the LLM provider in this deployment"
  type        = string
  default     = "https://api.groq.com/openai/v1"
}

variable "app_image_tag" {
  description = <<-EOT
    Full Artifact Registry image URI for the app/monitoring image, e.g.
    us-central1-docker.pkg.dev/<project_id>/db-rag-assistant/app:latest.
    Terraform does NOT build or push this image -- build and push it
    yourself first (see README "Cloud deployment" for the exact
    docker build / push commands), then pass the resulting URI here.
  EOT
  type        = string
}

variable "allow_public_access" {
  description = <<-EOT
    If true, both Cloud Run services accept unauthenticated requests
    (anyone with the URL can use them). Fine for a personal portfolio
    demo; set to false and set up IAM-based access instead for anything
    with real data or cost exposure.
  EOT
  type    = bool
  default = true
}

variable "cloud_sql_tier" {
  description = "Cloud SQL machine tier. db-f1-micro is the cheapest shared-core tier -- fine for a demo, not for production load."
  type        = string
  default     = "db-f1-micro"
}
