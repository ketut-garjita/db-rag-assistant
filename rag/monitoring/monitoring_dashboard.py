"""Monitoring dashboard: query volume, latency, and feedback across all
assistants (DB Schema Assistant, NL2SQL, etc.), read from query_logs."""
import os
import sys

import pandas as pd
import psycopg2
import streamlit as st
import altair as alt

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import get_pg_dsn  # noqa: E402

st.set_page_config(page_title="Monitoring Dashboard", page_icon="📊", layout="wide")
st.title("📊 RAG Monitoring Dashboard")
st.caption("Query volume, latency, and feedback across all assistants.")


@st.cache_data(ttl=30)
def load_logs() -> pd.DataFrame:
    conn = psycopg2.connect(get_pg_dsn())
    df = pd.read_sql(
        """
        SELECT
          log_id,
          app_name,
          question,
          model,
          response_time_ms,
          feedback,
          created_at,
          sources
        FROM query_logs
        ORDER BY created_at DESC
        """,
        conn,
    )
    def timing(name):
        def extract(value):
            if isinstance(value, dict):
                return value.get("timings", {}).get(name)
            return None
        return extract
    df["retrieval_ms"] = df["sources"].map(timing("retrieval_ms"))
    df["generation_ms"] = df["sources"].map(timing("generation_ms"))
    
    df["response_time_s"] = df["response_time_ms"] / 1000
    df["retrieval_s"] = df["retrieval_ms"] / 1000
    df["generation_s"] = df["generation_ms"] / 1000
    conn.close()
    return df

def build_model_benchmark(df: pd.DataFrame) -> pd.DataFrame:
    benchmark = (
        df.groupby(["model", "app_name"], dropna=False)
        .agg(
            avg_response_s=("response_time_s", "mean"),
            avg_retrieval_s=("retrieval_s", "mean"),
            avg_generation_s=("generation_s", "mean"),
            queries=("log_id", "count"),
            helpful=("feedback", lambda x: (x == "up").sum()),
            rated=("feedback", lambda x: x.isin(["up", "down"]).sum()),
        )
        .reset_index()
    )

    benchmark["helpful_rate"] = benchmark.apply(
        lambda row: (
            row["helpful"] / row["rated"]
            if row["rated"] > 0
            else None
        ),
        axis=1,
    )

    benchmark = benchmark.sort_values(
        ["app_name", "avg_response_s"],
        ascending=[True, True],
    )

    return benchmark

if st.button("🔄 Refresh"):
    st.cache_data.clear()

df = load_logs()

if df.empty:
    st.info("No queries logged yet. Ask something in the app first, then come back here.")
    st.stop()

# --- Recent queries table ---
st.subheader("Recent queries")

recent = df[
    [
        "created_at",
        "model",
        "app_name",
        "question",
        "response_time_s",
        "retrieval_s",
        "generation_s",
        "feedback",
    ]
].head(50)

st.dataframe(
    recent,
    use_container_width=True,
)

models = df["model"].dropna().unique()

if len(models) == 1:
    st.caption(f"Current logged model: `{models[0]}`")
else:
    st.caption(f"Models in history: {', '.join(models)}")

st.divider()

# --- Model benchmark ---

st.subheader("Model Benchmark")

benchmark = build_model_benchmark(df)

benchmark_display = benchmark[
    [
        "model",
        "app_name",
        "avg_response_s",
        "avg_retrieval_s",
        "avg_generation_s",
        "helpful_rate",
        "queries",
    ]
].copy()

benchmark_display.columns = [
    "Model",
    "App",
    "Avg Response",
    "Avg Retrieval",
    "Avg Generation",
    "Helpful",
    "Queries",
]

benchmark_display["Avg Response"] = (
    benchmark_display["Avg Response"].round(3).astype(str) + " s"
)

benchmark_display["Avg Retrieval"] = (
    benchmark_display["Avg Retrieval"].round(3).astype(str) + " s"
)

benchmark_display["Avg Generation"] = (
    benchmark_display["Avg Generation"].round(3).astype(str) + " s"
)

benchmark_display["Helpful"] = benchmark_display["Helpful"].apply(
    lambda x: f"{x:.0%}" if pd.notna(x) else "—"
)

st.dataframe(
    benchmark_display,
    use_container_width=True,
    hide_index=True,
)

# --- Top-level metrics ---
col1, col2, col3, col4 = st.columns(4)
col1.metric("Total queries", len(df))
col2.metric("Avg response time", f"{df['response_time_s'].mean():.0f} s")

up = int((df["feedback"] == "up").sum())
down = int((df["feedback"] == "down").sum())
rated = up + down
col3.metric("Helpful rate", f"{(up / rated):.0%}" if rated else "—")
col4.metric("Feedback given", f"{rated}/{len(df)}")

if df["generation_ms"].notna().any():
    st.subheader("Pipeline timing")
    t1, t2 = st.columns(2)
    t1.metric("Avg retrieval", f"{df['retrieval_s'].dropna().mean():.0f} s")
    t2.metric("Avg generation", f"{df['generation_s'].dropna().mean():.0f} s")

st.divider()

# --- Query volume over time ---
st.subheader("Query volume per day")
daily = df.copy()
daily["date"] = pd.to_datetime(daily["created_at"]).dt.date
st.bar_chart(daily.groupby("date").size())

# --- Breakdown by assistant ---
# --- Breakdown by assistant ---

# Consistent application colors:
# NL2SQL   -> blue
# schema_qa -> green
assistant_colors = alt.Scale(
    domain=["NL2SQL", "schema_qa"],
    range=["#1f77b4", "#2ca02c"],
)

col_a, col_b = st.columns(2)

with col_a:
    st.subheader("Queries by assistant")

    query_counts = (
        df["app_name"]
        .value_counts()
        .rename_axis("app_name")
        .reset_index(name="query_count")
    )

    chart_queries = (
        alt.Chart(query_counts)
        .mark_bar()
        .encode(
            x=alt.X(
                "app_name:N",
                title=None,
                sort=["NL2SQL", "schema_qa"],
                axis=alt.Axis(labelAngle=0),
            ),
            y=alt.Y(
                "query_count:Q",
                title="Queries",
            ),
            color=alt.Color(
                "app_name:N",
                scale=assistant_colors,
                legend=None,
            ),
            tooltip=[
                alt.Tooltip("app_name:N", title="Assistant"),
                alt.Tooltip("query_count:Q", title="Queries"),
            ],
        )
        .properties(height=350)
    )

    st.altair_chart(chart_queries, use_container_width=True)


with col_b:
    st.subheader("Avg response time by assistant (s)")

    avg_response = (
        df.groupby("app_name", as_index=False)["response_time_s"]
        .mean()
    )

    chart_response = (
        alt.Chart(avg_response)
        .mark_bar()
        .encode(
            x=alt.X(
                "app_name:N",
                title=None,
                sort=["NL2SQL", "schema_qa"],
                axis=alt.Axis(labelAngle=0),
            ),
            y=alt.Y(
                "response_time_s:Q",
                title="Seconds",
            ),
            color=alt.Color(
                "app_name:N",
                scale=assistant_colors,
                legend=None,
            ),
            tooltip=[
                alt.Tooltip("app_name:N", title="Assistant"),
                alt.Tooltip(
                    "response_time_s:Q",
                    title="Avg response",
                    format=".2f",
                ),
            ],
        )
        .properties(height=350)
    )

    st.altair_chart(chart_response, use_container_width=True)

# --- Feedback breakdown ---
col_c, col_d = st.columns(2)
with col_c:
    st.subheader("Feedback breakdown")
    feedback_counts = df["feedback"].fillna("no feedback").value_counts()
    st.bar_chart(feedback_counts)
with col_d:
    st.subheader("Avg response time trend (daily, s)")
    trend = daily.groupby("date")["response_time_s"].mean()
    st.line_chart(trend)

st.divider()
