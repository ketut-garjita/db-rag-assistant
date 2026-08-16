-- Enable the pgvector extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Storage table for document chunks and their embeddings
CREATE TABLE IF NOT EXISTS doc_chunks (
    id             BIGSERIAL PRIMARY KEY,
    source_type    TEXT NOT NULL DEFAULT 'local_file',  -- local_file, git, api, s3, db_catalog, etc.
    source_file    TEXT NOT NULL,
    table_name     TEXT,              -- DB table this chunk discusses, if any
    chunk_index    INT NOT NULL,
    content        TEXT NOT NULL,
    content_hash   TEXT NOT NULL,     -- md5(content), used to detect changes (skip re-embedding if unchanged)
    embedding      VECTOR(384),       -- must match EMBEDDING_DIM in .env
    ingested_at    TIMESTAMPTZ DEFAULT now(),
    updated_at     TIMESTAMPTZ DEFAULT now(),
    UNIQUE (source_file, chunk_index)
);

/*
-- Index for similarity search (cosine distance)
CREATE INDEX IF NOT EXISTS doc_chunks_embedding_idx
    ON doc_chunks USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- Full-text index for hybrid search (keyword)
CREATE INDEX IF NOT EXISTS doc_chunks_content_tsv_idx
    ON doc_chunks USING GIN (to_tsvector('english', content));
*/

-- =====================================================================
-- Monitoring: log of every question asked across assistants (DB Schema
-- Assistant, NL2SQL, etc.), used by app/monitoring_dashboard.py
-- =====================================================================
CREATE TABLE IF NOT EXISTS query_logs (
    log_id            BIGSERIAL PRIMARY KEY,
    app_name          VARCHAR(50) NOT NULL,   -- e.g. 'schema_qa', 'nl2sql'
    question          TEXT NOT NULL,
    answer            TEXT,
    sources           JSONB,                  -- retrieved chunks / generated SQL, etc.
    response_time_ms  INTEGER,
    feedback          VARCHAR(10) CHECK (feedback IN ('up', 'down')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
		model 						TEXT
);

CREATE INDEX IF NOT EXISTS idx_query_logs_created_at ON query_logs (created_at);
CREATE INDEX IF NOT EXISTS idx_query_logs_app_name ON query_logs (app_name);
CREATE INDEX IF NOT EXISTS idx_query_logs_feedback ON query_logs (feedback);


-- =====================================================================
-- Healthcare Data Platform — full DDL (17 tables)
-- Target: PostgreSQL 14+
-- CREATE TABLE order follows FK dependencies. The FK that forms a cycle
-- (departments <-> providers) is added via ALTER TABLE at the end of the file.
-- =====================================================================

-- =====================================================================
-- 1. patients — master patient data
-- =====================================================================
CREATE TABLE patients (
    patient_id      BIGSERIAL PRIMARY KEY,
    mrn             VARCHAR(20)  NOT NULL UNIQUE,
    full_name       VARCHAR(150) NOT NULL,
    date_of_birth   DATE         NOT NULL,
    gender          VARCHAR(10)  NOT NULL CHECK (gender IN ('male', 'female', 'other')),
    phone           VARCHAR(20),
    address         TEXT,
    registered_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  patients IS 'Master patient data — the single source of patient identity across systems.';
COMMENT ON COLUMN patients.mrn IS 'Medical Record Number, unique per hospital; never reuse an inactive MRN.';
COMMENT ON COLUMN patients.registered_at IS 'When the patient was first registered in the system.';

CREATE INDEX idx_patients_full_name ON patients (full_name);
CREATE INDEX idx_patients_date_of_birth ON patients (date_of_birth);


-- =====================================================================
-- 2. departments — hospital units/departments
--    (head_provider_id is added via ALTER at the end of the file,
--     since providers is only created after departments)
-- =====================================================================
CREATE TABLE departments (
    department_id    BIGSERIAL PRIMARY KEY,
    name              VARCHAR(100) NOT NULL UNIQUE,
    location          VARCHAR(150),
    head_provider_id  BIGINT,      -- FK to providers, added at the end of this file
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  departments IS 'Hospital units/departments, e.g. Cardiology, Radiology, ER.';
COMMENT ON COLUMN departments.head_provider_id IS 'Department head, references providers.provider_id.';

-- Natural Language to SQL feedback
CREATE TABLE nl2sql_feedback (
    id          BIGSERIAL PRIMARY KEY,
    question    TEXT NOT NULL,
    generated_sql TEXT NOT NULL,
    feedback    SMALLINT NOT NULL,  -- 0 = not helpful, 1 = helpful
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 3. providers — clinical staff (doctors, nurses, therapists)
-- =====================================================================
CREATE TABLE providers (
    provider_id      BIGSERIAL PRIMARY KEY,
    full_name        VARCHAR(150) NOT NULL,
    specialty        VARCHAR(100),
    license_number   VARCHAR(50)  NOT NULL UNIQUE,
    department_id    BIGINT       REFERENCES departments (department_id) ON DELETE SET NULL,
    is_active        BOOLEAN      NOT NULL DEFAULT true,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  providers IS 'Clinical staff: doctors, nurses, therapists.';
COMMENT ON COLUMN providers.license_number IS 'Medical practice license number, unique nationwide.';
COMMENT ON COLUMN providers.is_active IS 'False if the provider is no longer practicing (resigned/retired).';

CREATE INDEX idx_providers_department_id ON providers (department_id);
CREATE INDEX idx_providers_specialty ON providers (specialty);


-- =====================================================================
-- 4. appointments — planned visits
-- =====================================================================
CREATE TABLE appointments (
    appointment_id   BIGSERIAL PRIMARY KEY,
    patient_id       BIGINT      NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    provider_id      BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT,
    scheduled_at     TIMESTAMPTZ NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'scheduled'
                         CHECK (status IN ('scheduled', 'confirmed', 'cancelled', 'no_show', 'completed')),
    reason           TEXT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  appointments IS 'Planned visits; not necessarily realized.';
COMMENT ON COLUMN appointments.status IS 'If status becomes completed, one row is created in encounters referencing this appointment.';

CREATE INDEX idx_appointments_patient_id ON appointments (patient_id);
CREATE INDEX idx_appointments_provider_id ON appointments (provider_id);
CREATE INDEX idx_appointments_scheduled_at ON appointments (scheduled_at);


-- =====================================================================
-- 5. encounters — actual visits (main clinical data hub)
-- =====================================================================
CREATE TABLE encounters (
    encounter_id     BIGSERIAL PRIMARY KEY,
    patient_id       BIGINT      NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    provider_id      BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT,
    department_id    BIGINT      REFERENCES departments (department_id) ON DELETE SET NULL,
    appointment_id   BIGINT      REFERENCES appointments (appointment_id) ON DELETE SET NULL,
    encounter_type   VARCHAR(20) NOT NULL
                         CHECK (encounter_type IN ('outpatient', 'inpatient', 'emergency')),
    admitted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    discharged_at    TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_encounters_discharge_after_admit
        CHECK (discharged_at IS NULL OR discharged_at >= admitted_at)
);

COMMENT ON TABLE  encounters IS 'Actual visits (outpatient/inpatient/ER) — the main hub referenced by most other clinical tables.';
COMMENT ON COLUMN encounters.appointment_id IS 'Nullable — null when the encounter comes from a walk-in/ER visit with no appointment.';

CREATE INDEX idx_encounters_patient_id ON encounters (patient_id);
CREATE INDEX idx_encounters_provider_id ON encounters (provider_id);
CREATE INDEX idx_encounters_department_id ON encounters (department_id);
CREATE INDEX idx_encounters_admitted_at ON encounters (admitted_at);


-- =====================================================================
-- 6. diagnoses — diagnoses per encounter (ICD-10)
-- =====================================================================
CREATE TABLE diagnoses (
    diagnosis_id     BIGSERIAL PRIMARY KEY,
    encounter_id     BIGINT      NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    icd10_code       VARCHAR(10) NOT NULL,
    description      TEXT        NOT NULL,
    diagnosed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_primary       BOOLEAN     NOT NULL DEFAULT false
);

COMMENT ON TABLE  diagnoses IS 'Diagnoses recorded for an encounter, using ICD-10 codes.';
COMMENT ON COLUMN diagnoses.is_primary IS 'True for the primary diagnosis; an encounter should ideally have only one is_primary=true row.';

CREATE INDEX idx_diagnoses_encounter_id ON diagnoses (encounter_id);
CREATE INDEX idx_diagnoses_icd10_code ON diagnoses (icd10_code);

-- Enforce at the application/trigger level too: only one is_primary=true diagnosis per encounter.
CREATE UNIQUE INDEX uq_diagnoses_one_primary_per_encounter
    ON diagnoses (encounter_id) WHERE is_primary = true;


-- =====================================================================
-- 7. procedures — medical procedures per encounter (CPT)
-- =====================================================================
CREATE TABLE procedures (
    procedure_id     BIGSERIAL PRIMARY KEY,
    encounter_id     BIGINT      NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    cpt_code         VARCHAR(10) NOT NULL,
    description      TEXT        NOT NULL,
    performed_by     BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT,
    performed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  procedures IS 'Medical procedures performed during an encounter, using CPT codes.';

CREATE INDEX idx_procedures_encounter_id ON procedures (encounter_id);
CREATE INDEX idx_procedures_performed_by ON procedures (performed_by);
CREATE INDEX idx_procedures_cpt_code ON procedures (cpt_code);


-- =====================================================================
-- 8. medications — master medication catalog
-- =====================================================================
CREATE TABLE medications (
    medication_id            BIGSERIAL PRIMARY KEY,
    name                     VARCHAR(150) NOT NULL,
    generic_name             VARCHAR(150),
    form                     VARCHAR(20)  NOT NULL
                                 CHECK (form IN ('tablet', 'capsule', 'syrup', 'injection', 'ointment', 'inhaler')),
    strength                 VARCHAR(50),
    is_controlled_substance  BOOLEAN      NOT NULL DEFAULT false
);

COMMENT ON TABLE  medications IS 'Master medication catalog — not an individual patient prescription record.';
COMMENT ON COLUMN medications.is_controlled_substance IS 'True for narcotic/psychotropic drug classes, requires extra approval when prescribed.';

CREATE INDEX idx_medications_name ON medications (name);
CREATE INDEX idx_medications_generic_name ON medications (generic_name);


-- =====================================================================
-- 9. prescriptions — prescriptions issued during an encounter
-- =====================================================================
CREATE TABLE prescriptions (
    prescription_id   BIGSERIAL PRIMARY KEY,
    encounter_id      BIGINT      NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    medication_id     BIGINT      NOT NULL REFERENCES medications (medication_id) ON DELETE RESTRICT,
    prescribed_by     BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT,
    dosage            VARCHAR(50) NOT NULL,
    frequency         VARCHAR(50) NOT NULL,   -- e.g. '3 times a day', 'every 8 hours'
    duration_days     INT         NOT NULL CHECK (duration_days > 0),
    prescribed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  prescriptions IS 'Medication prescriptions issued during an encounter.';

CREATE INDEX idx_prescriptions_encounter_id ON prescriptions (encounter_id);
CREATE INDEX idx_prescriptions_medication_id ON prescriptions (medication_id);
CREATE INDEX idx_prescriptions_prescribed_by ON prescriptions (prescribed_by);


-- =====================================================================
-- 10. lab_orders — laboratory test orders
-- =====================================================================
CREATE TABLE lab_orders (
    lab_order_id   BIGSERIAL PRIMARY KEY,
    encounter_id   BIGINT      NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    test_type      VARCHAR(100) NOT NULL,     -- e.g. CBC, Lipid Panel, HbA1c
    ordered_by     BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT,
    ordered_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    status         VARCHAR(20) NOT NULL DEFAULT 'ordered'
                       CHECK (status IN ('ordered', 'collected', 'resulted', 'cancelled'))
);

COMMENT ON TABLE  lab_orders IS 'Laboratory test orders for an encounter.';

CREATE INDEX idx_lab_orders_encounter_id ON lab_orders (encounter_id);
CREATE INDEX idx_lab_orders_ordered_by ON lab_orders (ordered_by);
CREATE INDEX idx_lab_orders_status ON lab_orders (status);


-- =====================================================================
-- 11. lab_results — lab test results (one order can have many results)
-- =====================================================================
CREATE TABLE lab_results (
    lab_result_id    BIGSERIAL PRIMARY KEY,
    lab_order_id     BIGINT      NOT NULL REFERENCES lab_orders (lab_order_id) ON DELETE CASCADE,
    result_value     VARCHAR(50) NOT NULL,
    unit             VARCHAR(20),
    reference_range  VARCHAR(50),
    is_abnormal      BOOLEAN     NOT NULL DEFAULT false,
    resulted_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  lab_results IS 'Lab test results; a single lab_order can have many result parameters (e.g. CBC -> Hb, WBC, platelet count).';

CREATE INDEX idx_lab_results_lab_order_id ON lab_results (lab_order_id);
CREATE INDEX idx_lab_results_is_abnormal ON lab_results (is_abnormal) WHERE is_abnormal = true;


-- =====================================================================
-- 12. vitals — vital signs recorded during an encounter
-- =====================================================================
CREATE TABLE vitals (
    vital_id                    BIGSERIAL PRIMARY KEY,
    encounter_id                BIGINT      NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    recorded_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    heart_rate                  SMALLINT    CHECK (heart_rate BETWEEN 0 AND 300),
    blood_pressure_systolic     SMALLINT    CHECK (blood_pressure_systolic BETWEEN 0 AND 300),
    blood_pressure_diastolic    SMALLINT    CHECK (blood_pressure_diastolic BETWEEN 0 AND 200),
    temperature_celsius         NUMERIC(4,1) CHECK (temperature_celsius BETWEEN 25 AND 45),
    oxygen_saturation           SMALLINT    CHECK (oxygen_saturation BETWEEN 0 AND 100),
    recorded_by                 BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT
);

COMMENT ON TABLE  vitals IS 'Vital signs recorded during an encounter, usually by a nurse.';

CREATE INDEX idx_vitals_encounter_id ON vitals (encounter_id);
CREATE INDEX idx_vitals_recorded_at ON vitals (recorded_at);


-- =====================================================================
-- 13. allergies — patient allergy history (attached to the patient, not an encounter)
-- =====================================================================
CREATE TABLE allergies (
    allergy_id     BIGSERIAL PRIMARY KEY,
    patient_id     BIGINT      NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    allergen       VARCHAR(150) NOT NULL,
    reaction       TEXT,
    severity       VARCHAR(10) NOT NULL CHECK (severity IN ('mild', 'moderate', 'severe')),
    recorded_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  allergies IS 'Patient allergy history — attached to the patient for life, not per-encounter.';

CREATE INDEX idx_allergies_patient_id ON allergies (patient_id);


-- =====================================================================
-- 14. immunizations — patient immunization/vaccination history
-- =====================================================================
CREATE TABLE immunizations (
    immunization_id   BIGSERIAL PRIMARY KEY,
    patient_id        BIGINT      NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    vaccine_name       VARCHAR(100) NOT NULL,
    dose_number         SMALLINT    NOT NULL CHECK (dose_number > 0),
    administered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    administered_by    BIGINT      NOT NULL REFERENCES providers (provider_id) ON DELETE RESTRICT,
    lot_number         VARCHAR(50)
);

COMMENT ON TABLE  immunizations IS 'Patient immunization/vaccination history.';

CREATE INDEX idx_immunizations_patient_id ON immunizations (patient_id);


-- =====================================================================
-- 15. insurance_policies — patient insurance/coverage policies
-- =====================================================================
CREATE TABLE insurance_policies (
    policy_id        BIGSERIAL PRIMARY KEY,
    patient_id       BIGINT      NOT NULL REFERENCES patients (patient_id) ON DELETE CASCADE,
    payer_name       VARCHAR(100) NOT NULL,   -- e.g. a national health scheme, a private insurer
    policy_number    VARCHAR(50) NOT NULL,
    coverage_type    VARCHAR(50),
    valid_from       DATE        NOT NULL,
    valid_until      DATE,

    CONSTRAINT chk_insurance_valid_range
        CHECK (valid_until IS NULL OR valid_until >= valid_from),
    CONSTRAINT uq_insurance_payer_policy_number
        UNIQUE (payer_name, policy_number)
);

COMMENT ON TABLE  insurance_policies IS 'Insurance/coverage policies held by the patient.';

CREATE INDEX idx_insurance_policies_patient_id ON insurance_policies (patient_id);


-- =====================================================================
-- 16. claims — claims submitted to a payer/insurer for an encounter
-- =====================================================================
CREATE TABLE claims (
    claim_id          BIGSERIAL PRIMARY KEY,
    encounter_id      BIGINT        NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    policy_id         BIGINT        NOT NULL REFERENCES insurance_policies (policy_id) ON DELETE RESTRICT,
    claim_amount      NUMERIC(14,2) NOT NULL CHECK (claim_amount >= 0),
    approved_amount   NUMERIC(14,2) CHECK (approved_amount >= 0),
    status            VARCHAR(20)   NOT NULL DEFAULT 'submitted'
                          CHECK (status IN ('submitted', 'approved', 'rejected', 'partial')),
    submitted_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE  claims IS 'Claims submitted to a payer/insurer for an encounter.';

CREATE INDEX idx_claims_encounter_id ON claims (encounter_id);
CREATE INDEX idx_claims_policy_id ON claims (policy_id);
CREATE INDEX idx_claims_status ON claims (status);


-- =====================================================================
-- 17. billing_transactions — actual payment/billing transactions
-- =====================================================================
CREATE TABLE billing_transactions (
    transaction_id    BIGSERIAL PRIMARY KEY,
    encounter_id      BIGINT        NOT NULL REFERENCES encounters (encounter_id) ON DELETE CASCADE,
    claim_id          BIGINT        REFERENCES claims (claim_id) ON DELETE SET NULL,
    amount            NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
    payment_method    VARCHAR(20)   NOT NULL
                          CHECK (payment_method IN ('insurance', 'cash', 'card', 'bank_transfer')),
    paid_at           TIMESTAMPTZ   NOT NULL DEFAULT now()
);

COMMENT ON TABLE  billing_transactions IS 'Actual payment transactions; claim_id is null for out-of-pocket payments.';

CREATE INDEX idx_billing_transactions_encounter_id ON billing_transactions (encounter_id);
CREATE INDEX idx_billing_transactions_claim_id ON billing_transactions (claim_id);


-- =====================================================================
-- FK that forms a cycle (departments <-> providers), added after both
-- tables exist.
-- =====================================================================
ALTER TABLE departments
    ADD CONSTRAINT fk_departments_head_provider
    FOREIGN KEY (head_provider_id) REFERENCES providers (provider_id) ON DELETE SET NULL;

CREATE INDEX idx_departments_head_provider_id ON departments (head_provider_id);

