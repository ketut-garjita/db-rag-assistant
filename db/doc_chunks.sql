- Enable the pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Storage table for document chunks and their embeddings
CREATE TABLE IF NOT EXISTS doc_chunks (
    id             BIGSERIAL PRIMARY KEY,
    source_type    TEXT NOT NULL DEFAULT 'local_file',  -- local_file, git, api, s3, db_catalog, etc.
    source_file    TEXT NOT NULL,
    table_name     TEXT,              -- DB table this chunk discusses, if any
    chunk_index    INT NOT NULL,
    content        TEXT NOT NULL,
    content_hash   TEXT NOT NULL,     -- md5(content), used to detect changes (skip re-embedding if unchanged)
    embedding      VECTOR(384),       -- must match EMBEDDING_DIM in .env
    ingested_at    TIMESTAMPTZ DEFAULT now(),
    updated_at     TIMESTAMPTZ DEFAULT now(),
    UNIQUE (source_file, chunk_index)
);

-- Index for similarity search (cosine distance)
CREATE INDEX IF NOT EXISTS doc_chunks_embedding_idx
    ON doc_chunks USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- Full-text index for hybrid search (keyword)
CREATE INDEX IF NOT EXISTS doc_chunks_content_tsv_idx
    ON doc_chunks USING GIN (to_tsvector('english', content));
