"""LLM answer generation with bounded output and local-Ollama optimizations."""
import os
import sys
from openai import OpenAI

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import (  # noqa: E402
    LLM_MAX_TOKENS, LLM_MODEL, LLM_REASONING_EFFORT, LLM_TIMEOUT_SECONDS,
    OPENAI_API_KEY, OPENAI_BASE_URL,
)

_client = None
SYSTEM_PROMPT = """You are a database documentation assistant. Answer ONLY from the provided context.
Be concise and technical. Prefer a direct answer in 1-4 sentences or a short bullet list.
Do not invent tables, columns, relationships, or business rules. If the context is insufficient, say so.
Mention the relevant table name when useful."""

def _get_client() -> OpenAI:
    global _client
    if _client is None:
        _client = OpenAI(
            api_key=OPENAI_API_KEY,
            base_url=OPENAI_BASE_URL,
            timeout=LLM_TIMEOUT_SECONDS,
            max_retries=0,
        )
    return _client

def _ollama_reasoning_kwargs() -> dict:
    if OPENAI_BASE_URL and "ollama" in OPENAI_BASE_URL.lower() and LLM_REASONING_EFFORT:
        return {"reasoning_effort": LLM_REASONING_EFFORT}
    return {}

def build_prompt(question: str, contexts: list[dict]) -> str:
    context_block = "\n\n".join(
        f"[Source: {c['source_file']}"
        f"{', table: ' + c['table_name'] if c.get('table_name') else ''}]\n"
        f"{c['content']}"
        for c in contexts
    )
    return f"CONTEXT:\n{context_block}\n\nQUESTION: {question}\n\nANSWER:"

def generate_answer(question: str, contexts: list[dict]) -> str:
    response = _get_client().chat.completions.create(
        model=LLM_MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": build_prompt(question, contexts)},
        ],
        temperature=0.0,
        max_tokens=LLM_MAX_TOKENS,
        **_ollama_reasoning_kwargs(),
    )
    return (response.choices[0].message.content or "").strip()
