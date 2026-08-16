"""Retrieval: hybrid search (semantic + keyword) over the doc_chunks table,
plus query rewriting and cross-encoder re-ranking stages on top of it."""
import os
import re
import sys

import psycopg2

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import get_pg_dsn, EMBEDDING_MODEL, RERANKER_MODEL  # noqa: E402

_model = None
_reranker = None


def _get_model():
    global _model
    if _model is None:
        # Imported here (not at module top) so this heavy dependency chain
        # (sentence_transformers -> torch -> transformers -> sklearn/scipy)
        # only loads on first actual use, not on every module import. On a
        # serverless platform (e.g. Cloud Run) where instances can cold-start
        # per session, an eager top-level import here can block the entire
        # Streamlit session from starting -- the static page loads fine
        # (that's just HTML/JS), but the WebSocket-driven app session hangs
        # while this import chain (which can take a long time) runs.
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer(EMBEDDING_MODEL)
    return _model


def _get_reranker():
    global _reranker
    if _reranker is None:
        # Pre-downloaded at Docker build time (see Dockerfile) so this is
        # normally an in-image cache hit; falls back to downloading from
        # Hugging Face here if running outside that image. See _get_model()
        # above for why the import itself is deferred to here.
        from sentence_transformers import CrossEncoder
        _reranker = CrossEncoder(RERANKER_MODEL)
    return _reranker


def find_exact_table_match(query: str) -> str | None:
    """If the question literally mentions a table_name that exists in
    doc_chunks, return it. This lets hybrid_search short-circuit straight
    to that table's chunks instead of relying on generic keyword overlap
    (e.g. "table", "columns" appear in every schema chunk and would
    otherwise dilute relevance across unrelated tables). Longest table
    name is checked first to avoid partial-name collisions
    (e.g. "policy" inside "insurance_policies")."""
    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()
    cur.execute("SELECT DISTINCT table_name FROM doc_chunks WHERE table_name IS NOT NULL")
    tables = [r[0] for r in cur.fetchall()]
    cur.close()
    conn.close()

    q_lower = query.lower()
    for table in sorted(tables, key=len, reverse=True):
        if re.search(rf"\b{re.escape(table.lower())}\b", q_lower):
            return table
    return None


def search_by_table_name(table_name: str, top_k: int = 5) -> list[dict]:
    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()
    cur.execute(
        """
        SELECT source_file, table_name, content
        FROM doc_chunks
        WHERE table_name = %s
        LIMIT %s
        """,
        (table_name, top_k),
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()

    return [
        {"source_file": r[0], "table_name": r[1], "content": r[2], "score": 1.0}
        for r in rows
    ]


def semantic_search(query: str, top_k: int = 5) -> list[dict]:
    model = _get_model()
    query_emb = model.encode(query).tolist()

    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()
    cur.execute(
        """
        SELECT source_file, table_name, content,
               1 - (embedding <=> %s::vector) AS similarity
        FROM doc_chunks
        ORDER BY embedding <=> %s::vector
        LIMIT %s
        """,
        (query_emb, query_emb, top_k),
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()

    return [
        {"source_file": r[0], "table_name": r[1], "content": r[2], "score": r[3]}
        for r in rows
    ]


def keyword_search(query: str, top_k: int = 5) -> list[dict]:
    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()
    cur.execute(
        """
        SELECT source_file, table_name, content,
               ts_rank(to_tsvector('english', content), plainto_tsquery('english', %s)) AS rank
        FROM doc_chunks
        WHERE to_tsvector('english', content) @@ plainto_tsquery('english', %s)
        ORDER BY rank DESC
        LIMIT %s
        """,
        (query, query, top_k),
    )
    rows = cur.fetchall()
    cur.close()
    conn.close()

    return [
        {"source_file": r[0], "table_name": r[1], "content": r[2], "score": r[3]}
        for r in rows
    ]


def _fuse(query: str, top_k: int) -> list[dict]:
    """Reciprocal rank fusion of semantic + keyword search. This is the
    "hybrid" part — combining two retrievers — and is distinct from the
    cross-encoder re-ranking in rerank()/hybrid_search_reranked() below,
    which re-scores an already-fused candidate list with a slower but
    more accurate model."""
    semantic_results = semantic_search(query, top_k=top_k * 2)
    keyword_results = keyword_search(query, top_k=top_k * 2)

    scores: dict[str, float] = {}
    payload: dict[str, dict] = {}

    for rank, r in enumerate(semantic_results):
        key = r["content"]
        scores[key] = scores.get(key, 0) + 1 / (rank + 60)
        payload[key] = r

    for rank, r in enumerate(keyword_results):
        key = r["content"]
        scores[key] = scores.get(key, 0) + 1 / (rank + 60)
        payload[key] = r

    ranked = sorted(scores.items(), key=lambda x: x[1], reverse=True)[:top_k]
    return [payload[key] for key, _ in ranked]


def hybrid_search(query: str, top_k: int = 5) -> list[dict]:
    """Combine semantic + keyword search results via reciprocal rank
    fusion (see _fuse). First tries an exact table-name match (see
    find_exact_table_match): if the question literally names a table
    that exists in doc_chunks, return that table's chunks directly —
    this avoids generic words like "table"/"columns" (present in every
    chunk) pulling in unrelated tables. Falls back to fusion only when
    no table is named explicitly (e.g. "which table tracks order status
    changes?")."""
    exact_table = find_exact_table_match(query)
    if exact_table:
        return search_by_table_name(exact_table, top_k=top_k)
    return _fuse(query, top_k)


def rerank(query: str, results: list[dict], top_k: int | None = None) -> list[dict]:
    """Re-score a candidate list with a cross-encoder (jointly encodes
    query+document, so it's slower but more accurate than the bi-encoder
    cosine similarity used in semantic_search — good as a precision pass
    over a small candidate set, not for searching the whole table)."""
    if not results:
        return results

    reranker = _get_reranker()
    pairs = [(query, r["content"]) for r in results]
    scores = reranker.predict(pairs)

    for r, score in zip(results, scores):
        r["rerank_score"] = float(score)

    reranked = sorted(results, key=lambda r: r["rerank_score"], reverse=True)
    return reranked[:top_k] if top_k else reranked


def rewrite_query(query: str) -> str:
    """LLM-based query rewriting: reformulate a vague/colloquial question
    into a clearer, more specific search query before retrieval — e.g.
    resolving implicit references or spelling out likely table/column
    terms — so semantic + keyword search have more to match against.
    Falls back to the original query untouched if the LLM call fails,
    since a failed rewrite should degrade gracefully, not break search."""
    from rag.generation import _get_client  # reuse the same LLM client/config
    from config import LLM_MODEL

    prompt = (
        "Rewrite the following question into a clear, specific search "
        "query for a database-schema documentation search engine. Resolve "
        "vague references and make implied table/column terms explicit. "
        "If the question is already clear and specific, return it "
        "unchanged. Reply with ONLY the rewritten query, no explanation, "
        "no quotes.\n\n"
        f"Question: {query}\nRewritten query:"
    )
    try:
        client = _get_client()
        response = client.chat.completions.create(
            model=LLM_MODEL,
            messages=[{"role": "user", "content": prompt}],
            temperature=0,
        )
        rewritten = response.choices[0].message.content.strip()
        return rewritten if rewritten else query
    except Exception:
        return query


def hybrid_search_reranked(
    query: str, top_k: int = 5, candidate_k: int = 15, rewrite: bool | None = None
) -> list[dict]:
    """hybrid_search, but retrieves a wider candidate pool (candidate_k)
    and re-ranks it with a cross-encoder before cutting down to top_k.
    This is what rag/pipeline.py uses in production — see
    evaluation/evaluate.py for the comparison against plain hybrid_search
    that justifies it.

    Skips re-ranking on an exact table-name match, since search_by_table_name
    is already maximally precise (all rows are about the one named table);
    re-ranking a set that's already perfectly on-topic adds latency with
    no benefit. The exact-match check runs on BOTH the original and (if
    used) the rewritten query, since rewriting can surface a literal
    table name that wasn't explicit in the user's original phrasing.

    rewrite=None (default) reads config.ENABLE_QUERY_REWRITING; pass
    True/False explicitly to override (used by evaluate.py to compare
    both settings)."""
    if rewrite is None:
        from config import ENABLE_QUERY_REWRITING
        rewrite = ENABLE_QUERY_REWRITING

    exact_table = find_exact_table_match(query)
    if exact_table:
        return search_by_table_name(exact_table, top_k=top_k)

    search_query = rewrite_query(query) if rewrite else query

    if rewrite:
        exact_table = find_exact_table_match(search_query)
        if exact_table:
            return search_by_table_name(exact_table, top_k=top_k)

    candidates = _fuse(search_query, candidate_k)
    return rerank(search_query, candidates, top_k=top_k)