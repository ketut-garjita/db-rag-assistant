"""
INCREMENTAL ingestion pipeline: read documents (from local files, or other
sources via --source-type) -> chunk -> embed (only changed chunks) ->
upsert into pgvector -> delete stale chunks (source removed/shrunk).

Designed to be called repeatedly by an orchestrator (Kestra, cron, etc.)
without wiping and rebuilding the whole index on every run.

Usage:
    python ingestion/ingest.py --source data/ --source-type local_file
    python ingestion/ingest.py --source "host=db port=5432 dbname=postgres user=postgres password=postgres" --source-type db_catalog
"""
import argparse
import glob
import hashlib
import os
import sys

import psycopg2
from sentence_transformers import SentenceTransformer
from tqdm import tqdm

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import get_pg_dsn, EMBEDDING_MODEL  # noqa: E402


def chunk_text(text: str, chunk_size: int = 800, overlap: int = 150) -> list[str]:
    chunks, start = [], 0
    while start < len(text):
        chunks.append(text[start:start + chunk_size])
        start += chunk_size - overlap
    return [c.strip() for c in chunks if c.strip()]


def chunk_by_section(text: str) -> list[str]:
    """Heading-based chunking on markdown '## ...' — one chunk per
    table/entity, more coherent for schema-notes-style documents."""
    sections = text.split("\n## ")
    result = []
    for i, sec in enumerate(sections):
        sec = sec if i == 0 else "## " + sec
        sec = sec.strip()
        if sec:
            result.append(sec)
    return result


def load_local_documents(source_dir: str) -> list[tuple[str, str]]:
    """Source: local files (.md/.sql/.txt). Returns list of (source_file, raw_text)."""
    docs = []
    excluded_names = {
        "seed_data.sql",       # test rows are not schema documentation
        "doc_chunks.sql",      # storage-table DDL; never useful as user context
        "schema.sql",          # DDL + seed data; use schema_notes.md or db_catalog instead
    }
    for path in glob.glob(os.path.join(source_dir, "**", "*.*"), recursive=True):
        if os.path.basename(path) in excluded_names:
            continue
        if path.endswith((".md", ".sql", ".txt")):
            with open(path, "r", encoding="utf-8") as f:
                docs.append((os.path.relpath(path, source_dir), f.read()))
    return docs


def load_from_information_schema(dsn: str) -> list[tuple[str, str]]:
    """Source: introspect a live PostgreSQL database directly — no manual
    documentation needed. Generates one chunk per table from
    information_schema (columns, PK, FK, nullability) plus any COMMENT ON
    TABLE/COLUMN text already set on that database (see healthcare_ddl.sql
    for an example of a schema with such comments). Returns
    list[(source_file, text)], one "file" per table, formatted with the
    same '## Table: <name>' heading convention used by the markdown docs
    so chunk_by_section() and extract_table_name() work unchanged.

    dsn: a libpq connection string, e.g.
         "host=db port=5432 dbname=postgres user=postgres password=postgres"
    """
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()

    cur.execute(
        """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_type = 'BASE TABLE'
          AND table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name
        """
    )
    tables = cur.fetchall()

    docs = []
    for schema, table in tables:
        cur.execute("SELECT obj_description(%s::regclass)", (f'"{schema}"."{table}"',))
        table_comment_row = cur.fetchone()
        table_comment = table_comment_row[0] if table_comment_row else None

        cur.execute(
            """
            SELECT column_name, data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = %s AND table_name = %s
            ORDER BY ordinal_position
            """,
            (schema, table),
        )
        columns = cur.fetchall()

        cur.execute(
            """
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = %s AND tc.table_name = %s
            """,
            (schema, table),
        )
        pk_cols = {r[0] for r in cur.fetchall()}

        cur.execute(
            """
            SELECT kcu.column_name, ccu.table_name AS foreign_table, ccu.column_name AS foreign_column
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
              ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
            JOIN information_schema.constraint_column_usage ccu
              ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
            WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = %s AND tc.table_name = %s
            """,
            (schema, table),
        )
        fks = {r[0]: (r[1], r[2]) for r in cur.fetchall()}

        cur.execute(
            """
            SELECT a.attname, col_description(a.attrelid, a.attnum)
            FROM pg_attribute a
            JOIN pg_class c ON a.attrelid = c.oid
            JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE n.nspname = %s AND c.relname = %s AND a.attnum > 0 AND NOT a.attisdropped
            """,
            (schema, table),
        )
        col_comments = {r[0]: r[1] for r in cur.fetchall()}

        lines = [f"## Table: {table}"]
        if table_comment:
            lines.append(table_comment)
        lines.append("\nColumns:")
        for col_name, data_type, is_nullable in columns:
            tags = []
            if col_name in pk_cols:
                tags.append("PK")
            if col_name in fks:
                ftable, fcol = fks[col_name]
                tags.append(f"FK -> {ftable}.{fcol}")
            if is_nullable == "NO":
                tags.append("NOT NULL")
            tag_str = f" [{', '.join(tags)}]" if tags else ""
            comment = f" — {col_comments[col_name]}" if col_comments.get(col_name) else ""
            lines.append(f"- {col_name} ({data_type}){tag_str}{comment}")

        docs.append((f"{schema}.{table}.md", "\n".join(lines)))

    cur.close()
    conn.close()
    return docs


# Extension point: add other loaders here as needed, e.g.
# load_from_git(repo_url), load_from_api(endpoint), load_from_s3(bucket),
# or load_from_postgres_docs(url) for the official PostgreSQL documentation.
# Every loader just needs to return list[(source_file, text)] in this same
# shape, so the rest of the pipeline below stays unchanged.
SOURCE_LOADERS = {
    "local_file": load_local_documents,
    "db_catalog": load_from_information_schema,
}


def extract_table_name(chunk: str) -> str | None:
    if "## Table:" in chunk:
        line = [l for l in chunk.splitlines() if l.startswith("## Table:")][0]
        return line.replace("## Table:", "").strip()
    return None


def content_hash(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def main(source: str, source_type: str):
    if source_type not in SOURCE_LOADERS:
        raise ValueError(f"source_type '{source_type}' is not supported yet. "
                          f"Available: {list(SOURCE_LOADERS.keys())}")

    print(f"Loading documents from source '{source}' (type: {source_type}) ...")
    docs = SOURCE_LOADERS[source_type](source)
    print(f"Found {len(docs)} document(s).")

    model = None  # lazy-load, only if there's a new/changed chunk
    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()

    new_or_changed, unchanged, deleted = 0, 0, 0

    for source_file, raw_text in docs:
        chunks = (
            chunk_by_section(raw_text)
            if source_file.endswith(".md")
            else chunk_text(raw_text)
        )

        for idx, chunk in enumerate(tqdm(chunks, desc=source_file)):
            h = content_hash(chunk)
            cur.execute(
                "SELECT content_hash FROM doc_chunks WHERE source_file=%s AND chunk_index=%s",
                (source_file, idx),
            )
            row = cur.fetchone()

            if row and row[0] == h:
                unchanged += 1
                continue  # unchanged -> skip embedding, save API/compute cost

            if model is None:
                print(f"Loading embedding model: {EMBEDDING_MODEL} ...")
                model = SentenceTransformer(EMBEDDING_MODEL)

            embedding = model.encode(chunk, normalize_embeddings=True).tolist()
            table_name = extract_table_name(chunk)

            cur.execute(
                """
                INSERT INTO doc_chunks
                    (source_type, source_file, table_name, chunk_index,
                     content, content_hash, embedding, updated_at)
                VALUES (%s, %s, %s, %s, %s, %s, %s, now())
                ON CONFLICT (source_file, chunk_index) DO UPDATE SET
                    table_name = EXCLUDED.table_name,
                    content = EXCLUDED.content,
                    content_hash = EXCLUDED.content_hash,
                    embedding = EXCLUDED.embedding,
                    updated_at = now()
                """,
                (source_type, source_file, table_name, idx, chunk, h, embedding),
            )
            new_or_changed += 1

        # Delete stale chunks: indexes still in the DB that no longer exist
        # in the current version of the document (e.g. document was trimmed/revised)
        cur.execute(
            "DELETE FROM doc_chunks WHERE source_file=%s AND chunk_index >= %s",
            (source_file, len(chunks)),
        )
        deleted += cur.rowcount

    conn.commit()
    cur.close()
    conn.close()

    print(f"\nDone. New/changed: {new_or_changed} | Unchanged (skipped): "
          f"{unchanged} | Deleted (stale): {deleted}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="data/", help="Path/URL of the document source")
    parser.add_argument("--source-type", default="local_file",
                         help="local_file (default). Add a new loader in SOURCE_LOADERS for other types.")
    args = parser.parse_args()
    main(args.source, args.source_type)
