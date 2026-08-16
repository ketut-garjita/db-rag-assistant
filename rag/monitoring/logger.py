"""Logging helpers for the monitoring dashboard. Call log_query() right
after generating an answer in any assistant (schema QA, NL2SQL, etc.),
and update_feedback() (or feedback_from_int() for a binary 1/0 signal)
when the user clicks a thumbs up/down button."""
import json
import os
import sys

import psycopg2

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from config import get_pg_dsn  # noqa: E402


def log_query(
    app_name: str,
    question: str,
    answer: str,
    sources,
    response_time_ms: int,
    model: str,
) -> int:
    """Insert one row into query_logs and return its log_id."""
    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()

    cur.execute(
        """
        INSERT INTO query_logs (
            app_name,
            question,
            answer,
            sources,
            response_time_ms,
            model
        )
        VALUES (%s, %s, %s, %s, %s, %s)
        RETURNING log_id
        """,
        (
            app_name,
            question,
            answer,
            json.dumps(sources),
            response_time_ms,
            model,
        ),
    )

    log_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return log_id

def update_feedback(log_id: int, feedback: str) -> None:
    """feedback must be 'up' or 'down'."""
    conn = psycopg2.connect(get_pg_dsn())
    cur = conn.cursor()
    cur.execute("UPDATE query_logs SET feedback = %s WHERE log_id = %s", (feedback, log_id))
    conn.commit()
    cur.close()
    conn.close()


def feedback_from_int(log_id: int, value: int) -> None:
    """Convenience wrapper for UIs that use a binary 1/0 feedback signal
    (e.g. a legacy nl2sql_feedback table using 1=helpful, 0=not helpful).
    Maps 1 -> 'up' and 0 -> 'down', then calls update_feedback() so both
    assistants write to the same query_logs.feedback column and show up
    consistently on the monitoring dashboard."""
    update_feedback(log_id, "up" if value == 1 else "down")
