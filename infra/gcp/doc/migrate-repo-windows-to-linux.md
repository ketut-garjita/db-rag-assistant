# Windows to Linux Setup Migration - Google Cloud Platform

---
## Remove the ^M symbol

The ^M symbol typically represents the Carriage Return character (CR, \r, ASCII 13) originating from the Windows CRLF line ending (\r\n), whereas Linux usually uses LF (\n).

```
Windows 11
│
│ file uses CRLF (\r\n)
▼
Git repository
│
│ clone
▼
Linux VM
│
└── file remains CRLF
↓
^M
```

- Install dos2unix if it is not already installed:

```
sudo apt update
sudo apt install dos2unix
```

- Convert all files to LF

```
find . -type f \( \
  -name "*.yml" -o \
  -name "*.yaml" -o \
  -name "*.env" -o \
  -name "*.py" -o \
  -name "*.sql" -o \
  -name "*.md" -o \
  -name "*.txt" -o \
  -name "*.sh" -o \
  -name "*.json" \
\) -exec dos2unix {} +
```

- Everything is targeted at Linux/Docker

    ```
    git add .gitattributes
    git add --renormalize .
    ``` 

    Check:
    ```
    git status
    ```
    
    and then commit:
    ```
    git commit -m "Normalize text files to LF line endings"
    ```
    
    push:
    ```
    git push
    ```
    
    After that, on the Linux VM, o the following:
    ```
    git pull
    ```
    
    Git will use those .gitattributes rules to normalize text files to LF.
    
    To seek:
    ```
    grep -RIl $'\r' .
    
    ```
    
    **If it produces no output, it means there are no CR (^M) characters in the text file being checked.**

---
## Import Artifact Registry Repository

### In /infra/gcp
- Edit versions.tf
- Edit main.tf
- Edit variables.tf
- cp terraform.tfvars.examples terraform.tfvars
- Edit terraform.tfvars

Note: set `project_id`, `region`, `db_password`, `openai_api_key`, `llm_model`, `openai_base_url`, 
`cloud_sql_tier`, `app_image_tag`


### Services List

Login
```
gcloud auth login 
gcloud auth application-default login
gcloud config set project db-rag-assistant
```

State
```
cd infra/gcp
terraform state list
```

1. google_artifact_registry_repository.repo
2. google_cloud_run_v2_service.app
3. google_cloud_run_v2_service.monitoring
4. google_cloud_run_v2_service_iam_member.app_public[0]
5. google_cloud_run_v2_service_iam_member.monitoring_public[0]
6. google_project_iam_member.cloud_run_sql_client
7. google_project_service.apis["artifactregistry.googleapis.com"]
8. google_project_service.apis["iam.googleapis.com"]
9. google_project_service.apis["run.googleapis.com"]
10. google_project_service.apis["secretmanager.googleapis.com"]
11. google_project_service.apis["sqladmin.googleapis.com"]
12. google_secret_manager_secret.db_password
13. google_secret_manager_secret.openai_api_key
14. google_secret_manager_secret_iam_member.db_password_access
15. google_secret_manager_secret_iam_member.openai_key_access
16. google_secret_manager_secret_version.db_password
17. google_secret_manager_secret_version.openai_api_key
18. google_service_account.cloud_run_sa
19. google_sql_database_instance.postgres
20. google_sql_user.app_user
    

### Import Services

```
terraform import \
google_artifact_registry_repository.repo \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-app
```

```
terraform import \
google_cloud_run_v2_service.app \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-app
```

```
terraform import \
google_cloud_run_v2_service.monitoring \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_cloud_run_v2_service_iam_member.app_public[0] \
rojects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_cloud_run_v2_service_iam_member.monitoring_public[0] \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_project_iam_member.cloud_run_sql_client \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_project_service.apis["artifactregistry.googleapis.com"] \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_project_service.apis["iam.googleapis.com"] \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_project_service.apis["run.googleapis.com"] \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_project_service.apis["secretmanager.googleapis.com"] \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_project_service.apis["sqladmin.googleapis.com"] \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_secret_manager_secret.db_password \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_secret_manager_secret.openai_api_key \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_secret_manager_secret_iam_member.db_password_access \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_secret_manager_secret_iam_member.openai_key_access \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_secret_manager_secret_version.db_password \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_secret_manager_secret_version.openai_api_key \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_service_account.cloud_run_sa \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_sql_database_instance.postgres \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

```
terraform import \
google_sql_user.app_user \
projects/db-rag-assistant/locations/asia-southeast2/services/db-rag-monitoring
```

### Check the state

```
terraform state list
```

### fmt
```
terraform fmt
```

### validate
```
terraform validate
```

### plan
```
terraform plan
```

### apply
```
terraform apply
```

### Check the state again
```
terraform state list
```

---
## Build and push the image 

```
gcloud auth configure-docker asia-southeast2-docker.pkg.dev

docker build -t asia-southeast2-docker.pkg.dev/db-rag-assistant/db-rag-assistant/app:latest .

docker push asia-southeast2-docker.pkg.dev/db-rag-assistant/db-rag-assistant/app:latest
```

---
## Data Ingestion

- terminal 1 -- leave running

  cd to the repostory root directory

  ```  
  gcloud auth login                         
  gcloud config set project db-rag-assistant
  cloud-sql-proxy db-rag-assistant:asia-southeast2:db-rag-postgres --port 5433
  ```
  
- terminal 2

  cd to the repostory root directory

  - **Source type = local_file**

   ```
   gcloud auth login                         
   gcloud config set project db-rag-assistant
		
    docker run --rm \
      -e PG_HOST=host.docker.internal \
      -e PG_PORT=5433 \
      -e PG_DB=postgres \
      -e PG_USER=postgres \
      -e PG_PASSWORD=postgres \
      -e OPENAI_API_KEY=xxxxxxx \
      -e OPENAI_BASE_URL=https://api.groq.com/openai/v1 \
      -e LLM_MODEL=qwen/qwen3.8-27b asia-southeast2-docker.pkg.dev/db-rag-assistant/db-rag-assistant/app:latest python /app/rag/ingestion/ingest.py \
      --source /app/data \
      --source-type local_file
    ```

   - **Source type = db_catalog**
    ```
    docker run --rm \
      -e PG_HOST=host.docker.internal \
      -e PG_PORT=5433 \
      -e PG_DB=postgres \
      -e PG_USER=postgres \
      -e PG_PASSWORD=postgres \
      -e OPENAI_API_KEY=xxxxxxx \
      -e OPENAI_BASE_URL=https://api.groq.com/openai/v1 \
      -e LLM_MODEL=qwen/qwen3.8-27b asia-southeast2-docker.pkg.dev/db-rag-assistant/db-rag-assistant/app:latest python /app/rag/ingestion/ingest.py \
      --source "host=host.docker.internal port=5433 dbname=postgres user=postgres password=postgres" \
      --source-type db_catalog
    ```
