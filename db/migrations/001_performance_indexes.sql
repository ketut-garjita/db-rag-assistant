-- Apply once to an EXISTING database volume. New databases get these
-- objects from db/schema.sql automatically.
CREATE EXTENSION IF NOT EXISTS vector;

ALTER TABLE doc_chunks
    ADD COLUMN IF NOT EXISTS content_tsv TSVECTOR
    GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;

CREATE INDEX IF NOT EXISTS doc_chunks_embedding_hnsw_idx
    ON doc_chunks USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

CREATE INDEX IF NOT EXISTS doc_chunks_content_tsv_idx
    ON doc_chunks USING GIN (content_tsv);

CREATE INDEX IF NOT EXISTS doc_chunks_table_name_idx
    ON doc_chunks (table_name);
