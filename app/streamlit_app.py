"""Simple UI for the DB Schema & Query Assistant."""
import os
import sys
import time

import streamlit as st

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from rag.pipeline import answer_question  # noqa: E402
from nl2sql import ask_sql  # noqa: E402
from monitoring.logger import log_query, update_feedback, feedback_from_int  # noqa: E402
from config import LLM_MODEL

# --------------------
# DB Schema Assistant
# --------------------
st.set_page_config(page_title="DB Schema Assistant", page_icon="🗄️")
st.title("🗄️ DB Schema & Query Assistant")
st.caption("Ask anything about the database schema — answered from indexed documentation.")

if "history" not in st.session_state:
    st.session_state.history = []

question = st.text_input("Your question:", placeholder="e.g. What columns does billing_transaction have?")

if st.button("Ask") and question:
    with st.spinner("Searching for an answer..."):
        start = time.time()
        result = answer_question(question)
        elapsed_ms = int((time.time() - start) * 1000)
    log_sources = {
        "sources": result["sources"],
        "timings": result.get("timings", {}),
    }
    result["log_id"] = log_query(
        "schema_qa", result["question"], result["answer"], log_sources, elapsed_ms, model=LLM_MODEL
    )
    st.session_state.history.append(result)

for item in reversed(st.session_state.history):
    st.markdown(f"**Q:** {item['question']}")
    st.markdown(f"**A:** {item['answer']}")
    if item["sources"]:
        sources_str = ", ".join(
            f"{s['file']}" + (f" (table: {s['table']})" if s.get("table") else "")
            for s in item["sources"]
        )
        st.caption(f"Sources: {sources_str}")

    col1, col2 = st.columns(2)
    with col1:
        if st.button("👍 Helpful", key=f"up_{item['log_id']}"):
            update_feedback(item["log_id"], "up")
            st.toast("Thanks for the feedback!")
    with col2:
        if st.button("👎 Not quite right", key=f"down_{item['log_id']}"):
            update_feedback(item["log_id"], "down")
            st.toast("Thanks for the feedback!")
    st.divider()

# ---------------------------------------------------------------------------
# Natural Language -> SQL
# ---------------------------------------------------------------------------
st.subheader("💬 Ask in Natural Language → SQL")
nl_question = st.text_input(
    "Example: 'What is the total claim_amount grouped by status?'",
    key="nl2sql_input",
)

if nl_question:
    if st.session_state.get("nl2sql_question") != nl_question:
        st.session_state["nl2sql_question"] = nl_question
        st.session_state["nl2sql_result"] = ask_sql(nl_question)
        st.session_state["nl2sql_feedback_saved"] = None  # reset so a new question can be rated fresh

    sql, df, error, log_id = st.session_state["nl2sql_result"]
    st.code(sql, language="sql")
    if error:
        st.error(error)
    else:
        st.dataframe(df)

    # key includes log_id so each question gets its own independent widget
    # state -- otherwise a previous question's thumbs selection "sticks"
    # to the next one, since Streamlit persists widget state by key.
    feedback = st.feedback("thumbs", key=f"nl2sql_feedback_{log_id}")

    # only write once per value, not on every rerun the widget state persists across
    if feedback is not None and st.session_state.get("nl2sql_feedback_saved") != feedback:
        feedback_from_int(log_id, feedback)  # 1 -> "up", 0 -> "down" in query_logs
        st.session_state["nl2sql_feedback_saved"] = feedback
        st.toast("Thank you for the feedback!" if feedback == 1 else "Noted, will be corrected.")
