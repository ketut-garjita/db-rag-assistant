curl -v -u "admin@kestra.io:Admin1234$" -X POST http://localhost:8080/api/v1/main/flows -H "Content-Type: application/x-yaml" --data-binar "@./kestra/flows/local_file_ingestion.yaml"
curl -v -u "admin@kestra.io:Admin1234$" -X POST http://localhost:8080/api/v1/main/flows -H "Content-Type: application/x-yaml" --data-binar "@./kestra/flows/db_catalog_ingestion.yaml"
curl -v -u "admin@kestra.io:Admin1234$" -X POST http://localhost:8080/api/v1/main/flows -H "Content-Type: application/x-yaml" --data-binar "@./kestra/flows/rag_ingestion.yaml"
