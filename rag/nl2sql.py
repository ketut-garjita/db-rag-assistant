"""
nl2sql.py — Natural Language to SQL feature for db-rag-assistant
Note: Local Model Version (such as Ollama)

Flow:
  1. Retrieve relevant schema context from the doc_chunks table (the
     existing RAG index), filtered to source_type = 'db_catalog' so the
     LLM only sees table/column definitions, not free-form documents.
  2. Ask the LLM (via config.py -> OPENAI_BASE_URL, can be Ollama/OpenAI)
     to produce a SINGLE SELECT statement, no explanation.
  3. Validate the query (read-only, single statement, auto-LIMIT) before
     executing it.
  4. Execute against Postgres using a separate read-only connection,
     return a DataFrame.
  5. Log the interaction (question, generated SQL/error, response time)
     to query_logs so it shows up on the monitoring dashboard alongside
     the DB Schema Assistant.

Usage (in the existing Streamlit app.py):

    from nl2sql import ask_sql
    from monitoring.logger import feedback_from_int

    question = st.text_input("Question (natural language):")
    if question:
        sql, df, error, log_id = ask_sql(question)
        st.code(sql, language="sql")
        if error:
            st.error(error)
        else:
            st.dataframe(df)

        col1, col2 = st.columns(2)
        with col1:
            if st.button("👍 Helpful", key=f"up_{log_id}"):
                feedback_from_int(log_id, 1)   # -> "up" in query_logs
        with col2:
            if st.button("👎 Not quite right", key=f"down_{log_id}"):
                feedback_from_int(log_id, 0)   # -> "down" in query_logs
"""

import re
import time
from typing import List, Optional, Tuple

import pandas as pd
import psycopg2
from openai import OpenAI

from config import (
    get_pg_dsn,
    OPENAI_API_KEY,
    OPENAI_BASE_URL,
    LLM_MODEL,
    LLM_MAX_TOKENS,
    LLM_REASONING_EFFORT,
    LLM_TIMEOUT_SECONDS,
)
from monitoring.logger import log_query

# Helper

def make_log_sources(tables, retrieval_ms, generation_ms):
    return {
        "sources": tables,
        "timings": {
            "retrieval_ms": retrieval_ms,
            "generation_ms": generation_ms,
        },
    }

def clean_llm_sql(sql: str) -> str:
    """Normalize LLM output into a single SQL statement."""

    if not sql:
        return ""

    # Remove <think>...</think> reasoning blocks
    sql = re.sub(
        r"<think\b[^>]*>.*?</think\s*>",
        "",
        sql,
        flags=re.IGNORECASE | re.DOTALL,
    )

    # Remove markdown code fences
    sql = re.sub(
        r"```(?:sql)?",
        "",
        sql,
        flags=re.IGNORECASE,
    )

    # Remove any remaining closing fence
    sql = sql.replace("```", "")

    # Normalize whitespace
    sql = sql.strip()

    # Remove trailing semicolon
    sql = sql.rstrip(";").strip()

    return sql


# --- 1. Retrieve schema context from doc_chunks (pgvector) -----------------

def get_schema_context(question: str, top_k: int = 8) -> Tuple[str, List[str]]:
    """
    Reuses the exact same embedding model singleton as retrieval/retrieval.py
    (_get_model()) so SentenceTransformer isn't loaded twice in memory.
    Queries doc_chunks manually (instead of hybrid_search/semantic_search)
    because this needs the source_type='db_catalog' filter, which the
    functions in retrieval.py don't take as a parameter.

    Returns (schema_context_text, table_names) — table_names is used for
    the "sources" shown in the monitoring dashboard.
    """
    from retrieval.retrieval import _get_model  # reuse the singleton model, don't reload it

    model = _get_model()
    query_emb = model.encode(question).tolist()

    conn = psycopg2.connect(get_pg_dsn())
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT content, table_name
                FROM doc_chunks
                WHERE source_type = 'db_catalog'
                ORDER BY embedding <=> %s::vector
                LIMIT %s
                """,
                (query_emb, top_k),
            )
            rows = cur.fetchall()
    finally:
        conn.close()

    context = "\n\n".join(r[0] for r in rows)
    tables = sorted({r[1] for r in rows if r[1]})
    return context, tables


# --- 2. Generate SQL via the LLM --------------------------------------------

SYSTEM_PROMPT = """You are a PostgreSQL expert.
Given a database schema context and a natural-language question, output
ONLY a single valid PostgreSQL SELECT statement that answers the question.

Rules:
- Only SELECT statements. Never write/alter/delete data or schema.
- Never use INSERT, UPDATE, DELETE, DROP, ALTER, TRUNCATE, GRANT, CREATE.
- Use only tables/columns that appear in the provided schema context.
- If the question cannot be answered from the schema, reply exactly: NO_QUERY.
- Do not include explanations.
- Do not include markdown.
- Do not include code fences.
- Do not include SQL comments.
- Output exactly one SQL statement.
- Do not include reasoning.
- Do not output <think>...</think> blocks.
- Do not include a trailing semicolon.
"""


def generate_sql(question: str, schema_context: str) -> str:
    client = OpenAI(
        api_key=OPENAI_API_KEY,
        base_url=OPENAI_BASE_URL,
        timeout=LLM_TIMEOUT_SECONDS,
        max_retries=0,
    )

    resp = client.chat.completions.create(
        model=LLM_MODEL,
        temperature=0,
        max_tokens=LLM_MAX_TOKENS,
        **(
            {"reasoning_effort": LLM_REASONING_EFFORT}
            if (
                OPENAI_BASE_URL
                and "ollama" in OPENAI_BASE_URL.lower()
                and LLM_REASONING_EFFORT
            )
            else {}
        ),
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": (
                    f"Schema context:\n{schema_context}\n\n"
                    f"Question: {question}\n\n"
                    "SQL:"
                ),
            },
        ],
    )

    # ============================================================
    # RAW MODEL OUTPUT
    # ============================================================
    raw_sql = resp.choices[0].message.content or ""

    print("\n========== RAW LLM OUTPUT ==========")
    print(repr(raw_sql))
    print("====================================")

    sql = clean_llm_sql(raw_sql)

    print("\n========== CLEANED SQL ==========")
    print(repr(sql))
    print("=================================")

    return sql


    # ============================================================
    # REMOVE MARKDOWN CODE FENCES
    # ============================================================
    sql = re.sub(
        r"```(?:sql)?",
        "",
        sql,
        flags=re.IGNORECASE,
    )

    sql = sql.replace("```", "")

    # ============================================================
    # CLEAN WHITESPACE
    # ============================================================
    sql = sql.strip()

    # Remove trailing semicolon
    sql = sql.rstrip(";").strip()

    # ============================================================
    # DEBUG
    # ============================================================
    print("\n========== CLEANED SQL ==========")
    print(repr(sql))
    print("=================================")

    return sql

# --- 3. Query validation (guardrail) ----------------------------------------

FORBIDDEN = re.compile(
    r"\b(insert|update|delete|drop|alter|truncate|grant|revoke|create|comment|copy)\b",
    re.IGNORECASE,
)


def validate_sql(sql: str) -> Optional[str]:
    """Return an error message string if invalid, else None."""
    if not sql or sql.strip().upper() == "NO_QUERY":
        return "The question cannot be answered from the available schema."

    stripped = sql.strip().rstrip(";").strip()

    if ";" in stripped:
        return "Only a single SQL statement is allowed."

    if not re.match(r"^\s*(with|select)\b", stripped, re.IGNORECASE):
        return "Only SELECT (or WITH ... SELECT) queries are allowed."

    if FORBIDDEN.search(stripped):
        return "The query contains a disallowed command (not read-only)."

    return None


def add_limit_if_missing(sql: str, default_limit: int = 200) -> str:
    stripped = sql.strip().rstrip(";").strip()
    if re.search(r"\blimit\s+\d+\b", stripped, re.IGNORECASE):
        return stripped
    return f"{stripped}\nLIMIT {default_limit}"


# --- 4. Read-only execution --------------------------------------------------

def execute_sql(sql: str) -> pd.DataFrame:
    """
    Runs inside a read-only transaction so that even if a query somehow
    passed validation but turns out to write data, Postgres itself will
    reject it.
    """
    conn = psycopg2.connect(get_pg_dsn())
    try:
        conn.set_session(readonly=True, autocommit=True)
        df = pd.read_sql_query(sql, conn)
    finally:
        conn.close()
    return df


# --- End-to-end orchestration -------------------------------------------------

def ask_sql(question: str) -> Tuple[str, Optional[pd.DataFrame], Optional[str], int]:
    start = time.time()

    # -------------------------
    # Retrieval timing
    # -------------------------
    retrieval_start = time.time()

    schema_context, tables = get_schema_context(question)

    retrieval_ms = int(
        (time.time() - retrieval_start) * 1000
    )

    # Jika schema context tidak ditemukan
    if not schema_context.strip():
        error = "No schema context found for this question."

        log_sources = make_log_sources(
            tables,
            retrieval_ms=retrieval_ms,
            generation_ms=None,
        )

        log_id = log_query(
            "NL2SQL",
            question,
            error,
            log_sources,
            int((time.time() - start) * 1000),
            model=LLM_MODEL,
        )

        return "", None, error, log_id

    # -------------------------
    # Generation timing
    # -------------------------
    generation_start = time.time()

    sql = generate_sql(question, schema_context)

    generation_ms = int(
        (time.time() - generation_start) * 1000
    )

    log_sources = make_log_sources(
        tables,
        retrieval_ms=retrieval_ms,
        generation_ms=generation_ms,
    )

    # -------------------------
    # Validation
    # -------------------------
    print("\n========== NL2SQL DEBUG ==========")
    print("MODEL:", LLM_MODEL)
    print("BASE URL:", OPENAI_BASE_URL)
    print("RAW SQL repr:", repr(sql))
    print("SEMICOLON POSITIONS:", [m.start() for m in re.finditer(";", sql)])
    print("VALIDATION:", validate_sql(sql))
    print("==================================\n")

    err = validate_sql(sql)

    if err:
        answer = f"{sql}\n\n[REJECTED] {err}"

        log_id = log_query(
            "NL2SQL",
            question,
            answer,
            log_sources,
            int((time.time() - start) * 1000),
            model=LLM_MODEL,
        )

        return sql, None, err, log_id

    sql = add_limit_if_missing(sql)

    # -------------------------
    # Execute SQL
    # -------------------------
    try:
        df = execute_sql(sql)

    except Exception as e:
        error = f"Query execution failed: {e}"
        answer = f"{sql}\n\n[EXECUTION ERROR] {error}"

        log_id = log_query(
            "NL2SQL",
            question,
            answer,
            log_sources,
            int((time.time() - start) * 1000),
            model=LLM_MODEL,
        )

        return sql, None, error, log_id

    # -------------------------
    # Final logging
    # -------------------------
    log_id = log_query(
        "NL2SQL",
        question,
        sql,
        log_sources,
        int((time.time() - start) * 1000),
        model=LLM_MODEL,
    )

    return sql, df, None, log_id