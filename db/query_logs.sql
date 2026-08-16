-- Table: public.query_logs

-- DROP TABLE IF EXISTS public.query_logs;

CREATE TABLE IF NOT EXISTS public.query_logs
(
    log_id bigserial NOT NULL,
    app_name character varying(50) COLLATE pg_catalog."default" NOT NULL,
    question text COLLATE pg_catalog."default" NOT NULL,
    answer text COLLATE pg_catalog."default",
    sources jsonb,
    response_time_ms integer,
    feedback character varying(10) COLLATE pg_catalog."default",
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT query_logs_pkey PRIMARY KEY (log_id),
    CONSTRAINT query_logs_feedback_check CHECK (feedback::text = ANY (ARRAY['up'::character varying, 'down'::character varying]::text[]))
)

TABLESPACE pg_default;

ALTER TABLE IF EXISTS public.query_logs
    OWNER to postgres;
-- Index: idx_query_logs_app_name

-- DROP INDEX IF EXISTS public.idx_query_logs_app_name;

CREATE INDEX IF NOT EXISTS idx_query_logs_app_name
    ON public.query_logs USING btree
    (app_name COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_query_logs_created_at

-- DROP INDEX IF EXISTS public.idx_query_logs_created_at;

CREATE INDEX IF NOT EXISTS idx_query_logs_created_at
    ON public.query_logs USING btree
    (created_at ASC NULLS LAST)
    TABLESPACE pg_default;
-- Index: idx_query_logs_feedback

-- DROP INDEX IF EXISTS public.idx_query_logs_feedback;

CREATE INDEX IF NOT EXISTS idx_query_logs_feedback
    ON public.query_logs USING btree
    (feedback COLLATE pg_catalog."default" ASC NULLS LAST)
    TABLESPACE pg_default;