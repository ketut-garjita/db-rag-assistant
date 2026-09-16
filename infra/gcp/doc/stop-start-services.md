## Stop Services

Make the service status as follows:

- Cloud Run Service → idle / scale-to-zero
- Cloud Run Job     → No active execution.
- Cloud SQL         → STOPPED


### Cloud Run Service

db-rag-app
```
gcloud run services update db-rag-app \
  --region=asia-southeast2 \
  --min=0 \
  --max=0
```

db-rag-monitoring
```
gcloud run services update db-rag-monitoring \
  --region=asia-southeast2 \
  --min=0 \
  --max=0
```

### Cloud Run Job  
```
gcloud run jobs list \
  --region=asia-southeast2
```

### Cloud SQL
```
gcloud sql instances patch db-rag-postgres \
  --activation-policy=NEVER
```

Check status:
```
gcloud sql instances describe db-rag-postgres \
  --format="value(state)"
```

---
## Start Services

Make the service status as follows:

- Cloud Run Service → scale automatically
- Cloud Run Job     → there is active execution
- Cloud SQL         → RUNNABLE
  

### Cloud SQL
```
gcloud sql instances patch db-rag-postgres \
  --activation-policy=ALWAYS
```

Check:
```
gcloud sql instances describe db-rag-postgres \
  --format="value(state)"
```

Target:
```
RUNNABLE
```

Flow:
```
STOP
  ↓
activation-policy=NEVER

START
  ↓
activation-policy=ALWAYS
```

### Cloud Run Service

Cloud Run services typically scale automatically from zero when a request is received.

Check:

db-rag-app
```
gcloud run services describe db-rag-app \
  --region=asia-southeast2
```

db-rag-monitoring
```
gcloud run services describe db-rag-monitoring \
  --region=asia-southeast2
```

Then test:

db-rag-app
```
gcloud run services describe db-rag-app \
  --region=asia-southeast2 \
  --format="value(status.url)"
```

for example, obtaining the URL:
```
https://db-rag-app-xxxxx.asia-southeast2.run.app
```

db-rag-monitoring
```
gcloud run services describe db-rag-monitoring \
  --region=asia-southeast2 \
  --format="value(status.url)"
```

for example, obtaining the URL:
```
https://db-rag-app-yyyyy.asia-southeast2.run.app
```

The first request will cause Cloud Run to create an instance.

Flow:
```
OFF / idle

Cloud Run
   │
   │ request
   ▼
scale up
   │
   ▼
container running
```

---
