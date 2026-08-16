-- audit_enum_candidates.sql
--
-- Tujuan: cari kolom character varying / text / char di semua tabel user
-- (schema public) yang kemungkinan besar berisi nilai enum/status
-- (cardinality rendah = jumlah nilai unik sedikit dibanding total baris),
-- tapi belum punya COMMENT ON COLUMN.
--
-- Kolom seperti ini adalah kandidat utama untuk didokumentasikan, karena
-- RAG/NL2SQL assistant butuh tahu nilai valid apa saja (mis. status:
-- 'pending'/'approved'/'rejected') untuk generate SQL yang benar saat
-- user menyebut nilai spesifik di pertanyaan natural language.
--
-- Cara pakai: jalankan langsung di psql. Sesuaikan threshold di bagian
-- bawah (v_max_distinct, v_min_rows) sesuai kebutuhan.

DROP TABLE IF EXISTS _enum_audit_result;
CREATE TEMP TABLE _enum_audit_result (
    table_name      text,
    column_name     text,
    data_type       text,
    total_rows      bigint,
    distinct_values bigint,
    has_comment     boolean,
    sample_values   text
);

DO $$
DECLARE
    r RECORD;
    v_total_rows bigint;
    v_distinct   bigint;
    v_comment    text;
    v_samples    text;

    -- === Threshold, sesuaikan kalau perlu ===
    v_max_distinct int := 20;   -- anggap "enum-like" kalau nilai unik <= ini
    v_min_rows     int := 5;    -- skip tabel yang datanya terlalu sedikit untuk disimpulkan
BEGIN
    FOR r IN
        SELECT c.table_name, c.column_name, c.data_type
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_name = c.table_name AND t.table_schema = c.table_schema
        WHERE c.table_schema = 'public'
          AND t.table_type = 'BASE TABLE'
          AND c.data_type IN ('character varying', 'text', 'character')
        ORDER BY c.table_name, c.ordinal_position
    LOOP
        -- total baris di tabel
        EXECUTE format('SELECT count(*) FROM %I', r.table_name) INTO v_total_rows;

        IF v_total_rows < v_min_rows THEN
            CONTINUE;
        END IF;

        -- jumlah nilai unik di kolom ini (skip NULL)
        EXECUTE format(
            'SELECT count(DISTINCT %I) FROM %I WHERE %I IS NOT NULL',
            r.column_name, r.table_name, r.column_name
        ) INTO v_distinct;

        -- hanya lanjut kalau cardinality rendah -> kandidat enum
        IF v_distinct = 0 OR v_distinct > v_max_distinct THEN
            CONTINUE;
        END IF;

        -- cek apakah kolom sudah punya comment
        SELECT col_description(
            (quote_ident(r.table_name))::regclass::oid,
            ordinal_position
        ) INTO v_comment
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = r.table_name
          AND column_name = r.column_name;

        -- skip kalau sudah ada comment (fokus cuma yang BELUM didokumentasikan)
        IF v_comment IS NOT NULL THEN
            CONTINUE;
        END IF;

        -- ambil contoh nilai (max 8 nilai UNIK, dedup dulu baru limit --
        -- urutan sebelumnya (LIMIT lalu DISTINCT) salah: bisa melewatkan
        -- nilai unik yang baru muncul setelah baris ke-8)
        EXECUTE format(
            'SELECT string_agg(val, '', '') FROM (
                SELECT DISTINCT LEFT(%I::text, 40) AS val
                FROM %I
                WHERE %I IS NOT NULL
                ORDER BY val
                LIMIT 8
             ) sub',
            r.column_name, r.table_name, r.column_name
        ) INTO v_samples;

        -- tandai kalau distinct_values > 8 -> sample di bawah ini TIDAK lengkap
        IF v_distinct > 8 THEN
            v_samples := v_samples || ' [+' || (v_distinct - 8) || ' nilai lain, tidak ditampilkan]';
        END IF;

        INSERT INTO _enum_audit_result
        VALUES (r.table_name, r.column_name, r.data_type, v_total_rows, v_distinct, false, v_samples);
    END LOOP;
END $$;

-- Hasil, diurutkan dari cardinality paling rendah (paling jelas enum) dulu
SELECT
    table_name,
    column_name,
    data_type,
    total_rows,
    distinct_values,
    sample_values
FROM _enum_audit_result
ORDER BY distinct_values ASC, table_name;