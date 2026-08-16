import os
from dotenv import load_dotenv

load_dotenv()

PG_HOST = os.getenv("PG_HOST", "localhost")
PG_PORT = os.getenv("PG_PORT", "5432")
PG_DB = os.getenv("PG_DB", "postgres")
PG_USER = os.getenv("PG_USER", "postgres")
PG_PASSWORD = os.getenv("PG_PASSWORD", "postgres")

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY", "ollama")
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL")
LLM_MODEL = os.getenv("LLM_MODEL", "gpt-4o-mini")

# Keep local-model generation bounded. For Ollama/Qwen3, reasoning_effort=none
# disables the extra thinking pass and is usually the single biggest latency win
# for a documentation assistant.
LLM_TIMEOUT_SECONDS = float(os.getenv("LLM_TIMEOUT_SECONDS", "90"))
LLM_MAX_TOKENS = int(os.getenv("LLM_MAX_TOKENS", "256"))
LLM_REASONING_EFFORT = os.getenv("LLM_REASONING_EFFORT", "none")

EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "all-MiniLM-L6-v2")
EMBEDDING_DIM = int(os.getenv("EMBEDDING_DIM", "384"))

# Cross-encoder is accurate but CPU-expensive. Keep it opt-in for this small
# schema corpus; exact-table and hybrid retrieval already provide strong precision.
RERANKER_MODEL = os.getenv("RERANKER_MODEL", "cross-encoder/ms-marco-MiniLM-L-6-v2")
ENABLE_RERANKER = os.getenv("ENABLE_RERANKER", "false").lower() in {"1", "true", "yes", "on"}
RETRIEVAL_TOP_K = int(os.getenv("RETRIEVAL_TOP_K", "4"))
RETRIEVAL_CANDIDATE_K = int(os.getenv("RETRIEVAL_CANDIDATE_K", "10"))
ENABLE_QUERY_REWRITING = os.getenv("ENABLE_QUERY_REWRITING", "true")

# Small pool is enough for this application and avoids a new PostgreSQL
# connection on every retrieval operation.
DB_POOL_MIN = int(os.getenv("DB_POOL_MIN", "1"))
DB_POOL_MAX = int(os.getenv("DB_POOL_MAX", "6"))

def get_pg_dsn() -> str:
    return (
        f"host={PG_HOST} port={PG_PORT} dbname={PG_DB} "
        f"user={PG_USER} password={PG_PASSWORD}"
    )
