- **LLM: Groq instead of Ollama.** Ollama needs a GPU-capable, always-on host — not a fit for serverless Cloud Run (no GPU by default, cold starts discard any locally-cached model, no persistent disk for model weights). Groq's hosted, OpenAI-compatible API also turned out dramatically faster in side-by-side testing via the monitoring dashboard (sub-second responses vs. 10-45s for local Ollama models on modest hardware) — see `LLM_MODEL`/`OPENAI_BASE_URL` in `terraform.tfvars`. If you'd rather keep the LLM fully self-hosted in the cloud, run Ollama on a Compute Engine VM (ideally with a GPU) and point `openai_base_url` at it — not included here yet.
- **pgAdmin / Kestra stay local-only.** Both are operational/dev tools; exposing them publicly needs its own access-control design, which is out of scope for this deployment.
- **Cloud Run resource sizing for `app` (2 CPU / 2Gi memory,
  `startup_cpu_boost = true`, 600s timeout).** `app` imports
  `sentence-transformers` (pulling in `torch`, `transformers`,
  `scikit-learn`), a genuinely heavy dependency chain — undersized
  default Cloud Run resources make that import too slow for the
  platform's own startup/request timeouts. `monitoring` doesn't need
  this (no ML dependencies), so its resource defaults were left as-is.