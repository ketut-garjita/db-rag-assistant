"""Fast hybrid retrieval over pgvector + PostgreSQL full text search.

Performance principles:
- reuse the embedding model and DB connections
- exact table-name queries bypass expensive retrieval stages
- cross-encoder reranking is opt-in because it is CPU-heavy
- use indexed table_name / vector / tsvector expressions
"""
import os
import re
import sys
from functools import lru_cache

import psycopg2
from psycopg2.pool import ThreadedConnectionPool
from sentence_transformers import CrossEncoder, SentenceTransformer

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import (  # noqa: E402
    DB_POOL_MAX, DB_POOL_MIN, EMBEDDING_MODEL, ENABLE_RERANKER,
    RERANKER_MODEL, RETRIEVAL_CANDIDATE_K, get_pg_dsn,
)

_model = None
_reranker = None
_pool = None


def _get_pool():
    global _pool
    if _pool is None:
        _pool = ThreadedConnectionPool(DB_POOL_MIN, DB_POOL_MAX, dsn=get_pg_dsn())
    return _pool


def _query(sql, params=()):
    pool = _get_pool()
    conn = pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()
    finally:
        pool.putconn(conn)


def _get_model():
    global _model
    if _model is None:
        _model = SentenceTransformer(EMBEDDING_MODEL)
    return _model


def _get_reranker() -> CrossEncoder:
    global _reranker
    if _reranker is None:
        _reranker = CrossEncoder(RERANKER_MODEL)
    return _reranker


@lru_cache(maxsize=1)
def _table_names() -> tuple[str, ...]:
    rows = _query("SELECT DISTINCT table_name FROM doc_chunks WHERE table_name IS NOT NULL")
    return tuple(r[0] for r in rows)


def find_exact_table_match(query: str) -> str | None:
    q_lower = query.lower()
    for table in sorted(_table_names(), key=len, reverse=True):
        if re.search(rf"\b{re.escape(table.lower())}\b", q_lower):
            return table
    return None


def search_by_table_name(table_name: str, top_k: int = 5) -> list[dict]:
    rows = _query(
        """SELECT source_file, table_name, content
           FROM doc_chunks
           WHERE table_name = %s
           ORDER BY chunk_index
           LIMIT %s""",
        (table_name, top_k),
    )
    return [{"source_file": r[0], "table_name": r[1], "content": r[2], "score": 1.0} for r in rows]


def semantic_search(query: str, top_k: int = 5) -> list[dict]:
    query_emb = _get_model().encode(query, normalize_embeddings=True).tolist()
    rows = _query(
        """SELECT source_file, table_name, content,
                  1 - (embedding <=> %s::vector) AS similarity
           FROM doc_chunks
           WHERE embedding IS NOT NULL
           ORDER BY embedding <=> %s::vector
           LIMIT %s""",
        (query_emb, query_emb, top_k),
    )
    return [{"source_file": r[0], "table_name": r[1], "content": r[2], "score": float(r[3])} for r in rows]


def keyword_search(query: str, top_k: int = 5) -> list[dict]:
    rows = _query(
        """SELECT source_file, table_name, content,
                  ts_rank(content_tsv, plainto_tsquery('english', %s)) AS rank
           FROM doc_chunks
           WHERE content_tsv @@ plainto_tsquery('english', %s)
           ORDER BY rank DESC
           LIMIT %s""",
        (query, query, top_k),
    )
    return [{"source_file": r[0], "table_name": r[1], "content": r[2], "score": float(r[3])} for r in rows]


def _fuse(query: str, top_k: int) -> list[dict]:
    semantic_results = semantic_search(query, top_k=top_k * 2)
    keyword_results = keyword_search(query, top_k=top_k * 2)
    scores, payload = {}, {}
    for rank, result in enumerate(semantic_results):
        key = result["content"]
        scores[key] = scores.get(key, 0.0) + 1.0 / (rank + 60)
        payload[key] = result
    for rank, result in enumerate(keyword_results):
        key = result["content"]
        scores[key] = scores.get(key, 0.0) + 1.0 / (rank + 60)
        payload[key] = result
    return [payload[k] for k, _ in sorted(scores.items(), key=lambda x: x[1], reverse=True)[:top_k]]


def hybrid_search(query: str, top_k: int = 5) -> list[dict]:
    exact_table = find_exact_table_match(query)
    if exact_table:
        return search_by_table_name(exact_table, top_k=top_k)
    return _fuse(query, top_k)


def rerank(query: str, results: list[dict], top_k: int | None = None) -> list[dict]:
    if not results:
        return results
    scores = _get_reranker().predict([(query, r["content"]) for r in results])
    for result, score in zip(results, scores):
        result["rerank_score"] = float(score)
    ranked = sorted(results, key=lambda r: r["rerank_score"], reverse=True)
    return ranked[:top_k] if top_k else ranked


def hybrid_search_reranked(query: str, top_k: int = 5, candidate_k: int | None = None) -> list[dict]:
    exact_table = find_exact_table_match(query)
    if exact_table:
        return search_by_table_name(exact_table, top_k=top_k)

    candidates = _fuse(query, candidate_k or RETRIEVAL_CANDIDATE_K)
    if not ENABLE_RERANKER:
        return candidates[:top_k]
    return rerank(query, candidates, top_k=top_k)
