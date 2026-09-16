#!/bin/bash

set -e

KESTRA_URL="http://localhost:8080/api/v1/main/flows"
KESTRA_USER="admin@kestra.io"
KESTRA_PASSWORD='Admin1234$'

FLOWS=(
  "./kestra/flows/local_file_ingestion.yaml"
  "./kestra/flows/db_catalog_ingestion.yaml"
  "./kestra/flows/rag_ingestion.yaml"
)

for FLOW in "${FLOWS[@]}"; do
    echo "Deploying: $FLOW"

    curl -sS \
      -u "$KESTRA_USER:$KESTRA_PASSWORD" \
      -X POST "$KESTRA_URL" \
      -H "Content-Type: application/x-yaml" \
      --data-binary "@$FLOW"

    echo
    echo "----------------------------------------"
done

echo "All Kestra flows deployed successfully."
