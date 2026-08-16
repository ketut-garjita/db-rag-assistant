"""End-to-end schema RAG pipeline: retrieval -> generation."""
import os
import sys
import time

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from rag.config import RETRIEVAL_TOP_K  # noqa: E402
from rag.retrieval.retrieval import semantic_search
from rag.generation import generate_answer  # noqa: E402

def answer_question(question: str, top_k: int | None = None) -> dict:
    top_k = top_k or RETRIEVAL_TOP_K
    t0 = time.perf_counter()
    contexts = semantic_search(question, top_k=top_k)
    retrieval_ms = int((time.perf_counter() - t0) * 1000)
    if not contexts:
        return {
            "question": question,
            "answer": "No relevant context found in the documentation.",
            "sources": [],
            "timings": {"retrieval_ms": retrieval_ms, "generation_ms": 0},
        }
    t1 = time.perf_counter()
    answer = generate_answer(question, contexts)
    generation_ms = int((time.perf_counter() - t1) * 1000)
    return {
        "question": question,
        "answer": answer,
        "sources": [{"file": c["source_file"], "table": c.get("table_name")} for c in contexts],
        "timings": {"retrieval_ms": retrieval_ms, "generation_ms": generation_ms},
    }

if __name__ == "__main__":
    result = answer_question("What columns does the patients table have?")
    print("Q:", result["question"])
    print("A:", result["answer"])
    print("Sources:", result["sources"])
    print("Timings:", result["timings"])
