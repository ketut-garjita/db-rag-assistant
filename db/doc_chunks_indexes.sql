-- ============================================================
-- pgvector
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;


-- ============================================================
-- Full-text search column
-- ============================================================

ALTER TABLE doc_chunks
ADD COLUMN IF NOT EXISTS content_tsv
TSVECTOR
GENERATED ALWAYS AS (
    to_tsvector('english', content)
) STORED;


-- ============================================================
-- Vector similarity search
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_doc_chunks_embedding_hnsw
ON doc_chunks
USING hnsw (embedding vector_cosine_ops);


-- ============================================================
-- Full-text / keyword search
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_doc_chunks_content_tsv
ON doc_chunks
USING GIN (content_tsv);


-- ============================================================
-- Metadata filtering
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_doc_chunks_source_file
ON doc_chunks (source_file);

CREATE INDEX IF NOT EXISTS idx_doc_chunks_table_name
ON doc_chunks (table_name);

