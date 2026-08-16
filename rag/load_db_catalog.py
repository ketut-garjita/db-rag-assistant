#def load_db_catalog(dsn: str):
def load_from_information_schema(dsn: str):
    conn = psycopg2.connect(dsn)
    cur = conn.cursor()

    cur.execute("""
        SELECT
            table_schema,
            table_name
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog','information_schema')
        ORDER BY table_schema, table_name;
    """)

    docs = []

    for schema, table in cur.fetchall():

        cur.execute("""
            SELECT
                column_name,
                data_type,
                is_nullable
            FROM information_schema.columns
            WHERE table_schema=%s
              AND table_name=%s
            ORDER BY ordinal_position
        """, (schema, table))

        cols = cur.fetchall()

        text = f"## Table: {schema}.{table}\n\n"

        for name, dtype, nullable in cols:
            text += f"- {name}: {dtype} nullable={nullable}\n"

        docs.append((f"{schema}.{table}.md", text))

    cur.close()
    conn.close()

    return docs
