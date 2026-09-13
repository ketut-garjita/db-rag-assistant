## Cloud Deployment (GCP — live)

Deployed and verified working on Google Cloud via Terraform (`infra/gcp/`):
**Cloud Run** (`db-rag-app` + `db-rag-monitoring`, mirroring the two
Streamlit services in `docker-compose.yml`), **Cloud SQL for PostgreSQL**
(pgvector extension, region `asia-southeast2`), **Artifact Registry**,
and **Secret Manager** for credentials. The LLM provider is
[Groq](https://groq.com) (OpenAI-compatible endpoint, model
`qwen/qwen3.6-27b`) rather than a locally-hosted model — see
"Design decisions" below for why.

`ollama`, `pgadmin`, and `kestra` are intentionally **not** reproduced in
this cloud deployment — see "Design decisions" below.

#### Steps

1. Install the [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
   and Terraform ≥ 1.5.
2. Authenticate — **two separate logins are required**, for two different
   consumers of your Google credentials:
   ```bash
   gcloud auth login                          # for the gcloud CLI / docker push
   gcloud auth application-default login      # for Terraform's google provider
   gcloud config set project <project_id>
   ```
3. `cd infra/gcp && cp terraform.tfvars.example terraform.tfvars`, fill in
   real values (never commit this file — it's in `.gitignore`). Set
   `region` to wherever you want to deploy (`asia-southeast2` / Jakarta is
   confirmed to support every service this project uses).
4. Create the Artifact Registry repo first — you need it to exist before
   you can push an image to it:
   ```bash
   terraform init
   terraform apply -target=google_artifact_registry_repository.repo
   ```
5. Build and push the image (from the **repo root**, where the
   `Dockerfile` is — not from `infra/gcp/`):
   ```bash
   gcloud auth configure-docker <region>-docker.pkg.dev
   docker build -t <region>-docker.pkg.dev/<project_id>/db-rag-assistant/app:latest .
   docker push <region>-docker.pkg.dev/<project_id>/db-rag-assistant/app:latest
   ```
   Put that exact URI in `terraform.tfvars` as `app_image_tag`. If you're
   using Groq (or any non-OpenAI provider), also set `openai_base_url` in
   `terraform.tfvars` (e.g. `"https://api.groq.com/openai/v1"`) — leaving
   it unset makes the app call real OpenAI, which will reject a key from
   any other provider.
6. `terraform apply` again to create everything else (Cloud SQL, secrets,
   both Cloud Run services).
7. **Initialize the Cloud SQL schema** (Terraform provisions the instance
   but doesn't run SQL against it):
   ```bash
   gcloud sql connect db-rag-postgres --user=postgres
   # then, in psql:
   \i db/schema.sql
   ```
8. **Populate `doc_chunks`.** Cloud Run has no `docker exec` — run
   ingestion locally against the Cloud SQL instance through the Cloud SQL
   Auth Proxy instead:
   ```bash
   # terminal 1 -- leave running
   cloud-sql-proxy <project_id>:<region>:db-rag-postgres --port 5433

   # terminal 2
   docker run --rm \
     -e PG_HOST=host.docker.internal -e PG_PORT=5433 \
     -e PG_DB=postgres -e PG_USER=postgres -e PG_PASSWORD=<db_password> \
     -e OPENAI_API_KEY=<key> -e OPENAI_BASE_URL=<base_url> -e LLM_MODEL=<model> \
     <region>-docker.pkg.dev/<project_id>/db-rag-assistant/app:latest \
     python /app/rag/ingestion/ingest.py --source /app/data --source-type local_file

   docker run --rm \
     -e PG_HOST=host.docker.internal -e PG_PORT=5433 \
     -e PG_DB=postgres -e PG_USER=postgres -e PG_PASSWORD=<db_password> \
     -e OPENAI_API_KEY=<key> -e OPENAI_BASE_URL=<base_url> -e LLM_MODEL=<model> \
     <region>-docker.pkg.dev/<project_id>/db-rag-assistant/app:latest \
     python /app/rag/ingestion/ingest.py \
       --source "host=host.docker.internal port=5433 dbname=postgres user=postgres password=<db_password>" \
       --source-type db_catalog
   ```
   (Port 5433 rather than Postgres's default 5432 — see troubleshooting
   below for why.)
9. `terraform output` for the app and monitoring URLs.

#### Design Decisions
See [Cloud Design Decision](infra/gcp/doc/cloud-design-decisions.md)


#### Troubleshooting log
Real issues hit (and fixed) getting this deployment working, in case you hit the same ones see [gcp-deployment-troubleshooting](infra/gcp/doc/gcp-deployment-troubleshooting.md).

#### Screenshoots

![DB Schema & Query Assistant](assets/Screenshot-GCP-1.png)

![Monitoring Dashborad](assets/Screenshot-GCP-2.png)

![Resources](assets/Screenshot-GCP-3.png)

![Database](assets/Screenshot-GCP-4.png)
