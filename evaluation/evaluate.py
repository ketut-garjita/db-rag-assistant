"""
Evaluation suite for both retrieval and generation.

1. Retrieval evaluation: compares FOUR approaches (semantic-only,
   keyword-only, hybrid, hybrid+cross-encoder-reranked) on hit-rate and
   MRR, and reports the best one — this is what's actually used in
   rag/pipeline.py (hybrid_search_reranked).

2. Generation evaluation: compares TWO system-prompt variants using
   LLM-as-judge (the LLM rates each generated answer's relevance to the
   question on a 1-5 scale), and reports the best-scoring variant — the
   "default" prompt (rag/generation.SYSTEM_PROMPT) is what's actually
   shipped in production.

Note: generation evaluation makes several LLM calls per question
(one to generate + one to judge, per prompt variant). With a slow local
model (e.g. Ollama on modest hardware) this can take several minutes for
even a handful of questions — reduce eval_questions.json or point
OPENAI_BASE_URL at a faster model if you just want a quick smoke test.

Usage:
    python evaluation/evaluate.py                 # retrieval only (fast)
    python evaluation/evaluate.py --with-generation --generation-limit 10
"""
import json
import os
import re
import sys

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from rag.config import LLM_MODEL  # noqa: E402
from rag.retrieval.retrieval import (  # noqa: E402
    semantic_search,
    keyword_search,
    hybrid_search,
    hybrid_search_reranked,
)
from rag.generation import _get_client, build_prompt, SYSTEM_PROMPT  # noqa: E402


def load_eval_set(path: str = "/app/evaluation/eval_questions.json") -> list[dict]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# =============================================================================
# 1. Retrieval evaluation — compare multiple approaches
# =============================================================================

RETRIEVAL_APPROACHES = {
    "semantic_only": semantic_search,
    "keyword_only": keyword_search,
    "hybrid": hybrid_search,
    "hybrid_reranked": hybrid_search_reranked,  # what rag/pipeline.py actually uses
}


def evaluate_retrieval_approach(search_fn, eval_set: list[dict], top_k: int = 5) -> dict:
    hits = 0
    reciprocal_ranks = []

    for item in eval_set:
        results = search_fn(item["question"], top_k=top_k)
        tables_retrieved = [r.get("table_name") for r in results]

        if item["expected_table"] in tables_retrieved:
            hits += 1
            rank = tables_retrieved.index(item["expected_table"]) + 1
            reciprocal_ranks.append(1 / rank)
        else:
            reciprocal_ranks.append(0)

    return {
        "hit_rate": hits / len(eval_set),
        "mrr": sum(reciprocal_ranks) / len(reciprocal_ranks),
    }


def evaluate_retrieval(eval_set: list[dict], top_k: int = 5) -> tuple[dict, str]:
    """Returns (per_approach_metrics, best_approach_name)."""
    results = {}
    for name, search_fn in RETRIEVAL_APPROACHES.items():
        results[name] = evaluate_retrieval_approach(search_fn, eval_set, top_k=top_k)

    best = max(results, key=lambda name: (results[name]["hit_rate"], results[name]["mrr"]))
    return results, best


# =============================================================================
# 2. Generation evaluation — compare multiple prompts via LLM-as-judge
# =============================================================================

PROMPT_VARIANTS = {
    "default": SYSTEM_PROMPT,  # the prompt actually shipped in rag/generation.py
    "concise": """You are a terse database documentation assistant. Answer
in at most two short sentences, using ONLY the provided context. If the
answer isn't in the context, say so in one sentence. Do not cite sources
or add caveats beyond that.""",
}


def generate_with_prompt(question: str, contexts: list[dict], system_prompt: str) -> str:
    client = _get_client()
    response = client.chat.completions.create(
        model=LLM_MODEL,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": build_prompt(question, contexts)},
        ],
        temperature=0.1,
    )
    return response.choices[0].message.content


def judge_answer(question: str, answer: str) -> int:
    """LLM-as-judge: score 1 (unhelpful) to 5 (excellent) for how well the
    answer addresses the question. Returns 0 if the judge's reply can't be
    parsed (treated as a failing score, not a crash)."""
    client = _get_client()
    judge_prompt = (
        f"Question: {question}\nAnswer: {answer}\n\n"
        "Rate how relevant and helpful this answer is to the question, "
        "on a scale of 1 (not helpful) to 5 (excellent). "
        "Reply with ONLY a single digit, nothing else."
    )
    response = client.chat.completions.create(
        model=LLM_MODEL,
        messages=[{"role": "user", "content": judge_prompt}],
        temperature=0,
    )
    match = re.search(r"\d", response.choices[0].message.content)
    return int(match.group()) if match else 0


def evaluate_generation(eval_set: list[dict], top_k: int = 5) -> tuple[dict, str]:
    """Returns (per_prompt_avg_score, best_prompt_name)."""
    results = {}
    for name, prompt in PROMPT_VARIANTS.items():
        scores = []
        for item in eval_set:
            contexts = hybrid_search(item["question"], top_k=top_k)
            answer = generate_with_prompt(item["question"], contexts, prompt)
            scores.append(judge_answer(item["question"], answer))
        results[name] = sum(scores) / len(scores)

    best = max(results, key=results.get)
    return results, best


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Evaluate healthcare RAG retrieval and optionally generation.")
    parser.add_argument("--with-generation", action="store_true",
                        help="Run expensive LLM generation + LLM-as-judge evaluation.")
    parser.add_argument("--generation-limit", type=int, default=10,
                        help="Maximum questions used for generation evaluation (default: 10).")
    parser.add_argument("--top-k", type=int, default=5)
    args = parser.parse_args()

    eval_set = load_eval_set()

    print(f"=== Retrieval evaluation ({len(eval_set)} questions) ===")
    retrieval_results, best_retrieval = evaluate_retrieval(eval_set, top_k=args.top_k)
    for name, metrics in retrieval_results.items():
        marker = " <- best" if name == best_retrieval else ""
        print(f"{name:15s} hit-rate={metrics['hit_rate']:.2%}  mrr={metrics['mrr']:.3f}{marker}")

    if args.with_generation:
        generation_set = eval_set[:max(1, min(args.generation_limit, len(eval_set)))]
        print(f"\n=== Generation evaluation ({len(generation_set)} questions, LLM-as-judge) ===")
        print("Generation evaluation is intentionally opt-in because it makes multiple LLM calls per question.")
        generation_results, best_generation = evaluate_generation(generation_set, top_k=args.top_k)
        for name, avg_score in generation_results.items():
            marker = " <- best" if name == best_generation else ""
            print(f"{name:10s} avg_relevance_score={avg_score:.2f}/5{marker}")
    else:
        print("\nGeneration evaluation skipped. Use --with-generation for an LLM quality test.")
