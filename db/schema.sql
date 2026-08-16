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
	  model 			      TEXT
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


-- =====================================================================
-- Notes
-- =====================================================================
-- - Only use synthetic/dummy data for practice; never ingest real
--   patient data without proper anonymization and access controls
--   compliant with applicable regulations (e.g. HIPAA or your local
--   data protection law).
-- - The uq_diagnoses_one_primary_per_encounter constraint uses a
--   partial unique index because PostgreSQL doesn't support "unique
--   per filtered group" through a plain CHECK constraint.
-- - Some business rules (e.g. total approved claim amounts should not
--   exceed the claim amount) are better enforced via a trigger or at
--   the application layer, not through a simple CHECK constraint.


-- =====================================================================
-- Healthcare Data Platform — representative dummy seed data (not real
-- patient data). Run after healthcare_ddl.sql.
-- INSERT order follows FK dependencies.
-- =====================================================================

-- 1. departments (head_provider_id is filled in later via UPDATE, since
--    providers doesn't exist yet when departments is first inserted)
INSERT INTO departments (department_id, name, location) VALUES
    (1, 'Cardiology', 'Gedung A, Lantai 3'),
    (2, 'Radiology', 'Gedung A, Lantai 1'),
    (3, 'Emergency', 'Gedung B, Lantai Dasar'),
    (4, 'Internal Medicine', 'Gedung A, Lantai 2'),
    (5, 'Pediatrics', 'Gedung C, Lantai 1');

-- 2. providers
INSERT INTO providers (provider_id, full_name, specialty, license_number, department_id, is_active) VALUES
    (1, 'dr. Andi Wijaya, Sp.JP', 'Cardiology', 'LIC-1001', 1, true),
    (2, 'dr. Siti Rahma, Sp.JP', 'Cardiology', 'LIC-1002', 1, true),
    (3, 'dr. Budi Santoso, Sp.Rad', 'Radiology', 'LIC-1003', 2, true),
    (4, 'dr. Rina Kusuma, Sp.Rad', 'Radiology', 'LIC-1004', 2, true),
    (5, 'dr. Hendra Saputra, Sp.EM', 'Emergency Medicine', 'LIC-1005', 3, true),
    (6, 'dr. Maya Anggraini, Sp.EM', 'Emergency Medicine', 'LIC-1006', 3, true),
    (7, 'dr. Fajar Nugroho, Sp.PD', 'Internal Medicine', 'LIC-1007', 4, true),
    (8, 'dr. Dewi Lestari, Sp.A', 'Pediatrics', 'LIC-1008', 5, true);

-- Set each department's head after providers exists
UPDATE departments SET head_provider_id = 1 WHERE department_id = 1;
UPDATE departments SET head_provider_id = 3 WHERE department_id = 2;
UPDATE departments SET head_provider_id = 5 WHERE department_id = 3;
UPDATE departments SET head_provider_id = 7 WHERE department_id = 4;
UPDATE departments SET head_provider_id = 8 WHERE department_id = 5;

-- =====================================================================
-- Healthcare Data Platform -- expanded dummy seed data (not real
-- patient data). Run after healthcare_ddl.sql.
-- Generated programmatically (see generate_seed.py) for volume + FK
-- integrity across 17 tables, 200+ total rows.
-- INSERT order follows FK dependencies.
-- =====================================================================

-- 1. departments (head_provider_id filled in later via UPDATE)
INSERT INTO departments (department_id, name, location) VALUES
    (1, 'Cardiology', 'Gedung A, Lantai 3'),
    (2, 'Radiology', 'Gedung A, Lantai 1'),
    (3, 'Emergency', 'Gedung B, Lantai Dasar'),
    (4, 'Internal Medicine', 'Gedung A, Lantai 2'),
    (5, 'Pediatrics', 'Gedung C, Lantai 1');

-- 2. providers
INSERT INTO providers (provider_id, full_name, specialty, license_number, department_id, is_active) VALUES
    (1, 'dr. Hendra Saputra, Sp.JP', 'Cardiology', 'LIC-1001', 1, false),
    (2, 'dr. Slamet Riyadi, Sp.Rad', 'Radiology', 'LIC-1002', 2, true),
    (3, 'dr. Fajar Nugroho, Sp.EM', 'Emergency Medicine', 'LIC-1003', 3, true),
    (4, 'dr. Yuni Astuti, Sp.PD', 'Internal Medicine', 'LIC-1004', 4, true),
    (5, 'dr. Maya Anggraini, Sp.A', 'Pediatrics', 'LIC-1005', 5, false),
    (6, 'dr. Andi Wijaya, Sp.JP', 'Cardiology', 'LIC-1006', 1, true),
    (7, 'dr. Ratna Sari, Sp.Rad', 'Radiology', 'LIC-1007', 2, true),
    (8, 'dr. Putri Wijayanti, Sp.EM', 'Emergency Medicine', 'LIC-1008', 3, true),
    (9, 'dr. Rina Kusuma, Sp.PD', 'Internal Medicine', 'LIC-1009', 4, true),
    (10, 'dr. Sari Indah, Sp.A', 'Pediatrics', 'LIC-1010', 5, true),
    (11, 'dr. Ahmad Fauzi, Sp.JP', 'Cardiology', 'LIC-1011', 1, true),
    (12, 'dr. Eko Purnomo, Sp.Rad', 'Radiology', 'LIC-1012', 2, true),
    (13, 'dr. Ani Suryani, Sp.EM', 'Emergency Medicine', 'LIC-1013', 3, true),
    (14, 'dr. Hadi Susanto, Sp.PD', 'Internal Medicine', 'LIC-1014', 4, true),
    (15, 'dr. Budi Santoso, Sp.A', 'Pediatrics', 'LIC-1015', 5, true);

-- Set each department's head after providers exists
UPDATE departments SET head_provider_id = 1 WHERE department_id = 1;
UPDATE departments SET head_provider_id = 2 WHERE department_id = 2;
UPDATE departments SET head_provider_id = 3 WHERE department_id = 3;
UPDATE departments SET head_provider_id = 4 WHERE department_id = 4;
UPDATE departments SET head_provider_id = 5 WHERE department_id = 5;

-- 3. patients
INSERT INTO patients (patient_id, mrn, full_name, date_of_birth, gender, phone, address, registered_at) VALUES
    (1, 'MRN-0001', 'Wahyu Ramadhan', '1994-10-09', 'male', '081234567801', 'Jl. Cendana No. 6, Solo', '2022-10-25'),
    (2, 'MRN-0002', 'Yusuf Maulana', '1960-09-10', 'male', '081234567802', 'Jl. Kenanga No. 81, Palembang', '2021-02-25'),
    (3, 'MRN-0003', 'Rudi Hartono', '1955-11-08', 'male', '081234567803', 'Jl. Cendana No. 38, Bandung', '2018-12-17'),
    (4, 'MRN-0004', 'Yusuf Maulana', '1985-08-21', 'male', '081234567804', 'Jl. Kenanga No. 47, Surabaya', '2021-04-19'),
    (5, 'MRN-0005', 'Rina Kusuma', '1984-12-22', 'female', '081234567805', 'Jl. Mawar No. 10, Palembang', '2025-10-20'),
    (6, 'MRN-0006', 'Slamet Riyadi', '1981-03-15', 'male', '081234567806', 'Jl. Veteran No. 35, Denpasar', '2024-06-22'),
    (7, 'MRN-0007', 'Eko Purnomo', '1957-04-27', 'male', '081234567807', 'Jl. Merdeka No. 41, Bogor', '2019-07-22'),
    (8, 'MRN-0008', 'Budi Santoso', '1990-04-21', 'male', '081234567808', 'Jl. Kartini No. 51, Denpasar', '2022-10-22'),
    (9, 'MRN-0009', 'Fajar Nugroho', '1967-04-24', 'male', '081234567809', 'Jl. Cendrawasih No. 69, Yogyakarta', '2024-12-11'),
    (10, 'MRN-0010', 'Melati Putri', '2001-06-08', 'female', '081234567810', 'Jl. Gatot Subroto No. 66, Medan', '2016-07-18'),
    (11, 'MRN-0011', 'Agus Salim', '1969-11-06', 'male', '081234567811', 'Jl. Cendana No. 88, Bogor', '2025-02-22'),
    (12, 'MRN-0012', 'Yusuf Maulana', '1998-10-15', 'male', '081234567812', 'Jl. Cendrawasih No. 33, Makassar', '2015-03-13'),
    (13, 'MRN-0013', 'Slamet Riyadi', '1984-11-11', 'male', '081234567813', 'Jl. Sudirman No. 38, Bogor', '2017-09-09'),
    (14, 'MRN-0014', 'Sri Wahyuni', '1983-09-25', 'female', '081234567814', 'Jl. Gatot Subroto No. 65, Bandung', '2025-08-21'),
    (15, 'MRN-0015', 'Nina Kurnia', '1975-03-12', 'female', '081234567815', 'Jl. Cendana No. 21, Makassar', '2024-01-09'),
    (16, 'MRN-0016', 'Arief Budiman', '1991-08-01', 'male', '081234567816', 'Jl. Sudirman No. 47, Depok', '2020-03-25'),
    (17, 'MRN-0017', 'Bambang Setiawan', '1980-10-03', 'male', '081234567817', 'Jl. Sudirman No. 94, Medan', '2016-03-06'),
    (18, 'MRN-0018', 'Joko Prasetyo', '2010-09-06', 'male', '081234567818', 'Jl. Ahmad Yani No. 68, Depok', '2025-04-27'),
    (19, 'MRN-0019', 'Rina Kusuma', '2019-12-23', 'female', '081234567819', 'Jl. Diponegoro No. 92, Yogyakarta', '2023-05-15'),
    (20, 'MRN-0020', 'Yuni Astuti', '2016-08-04', 'female', '081234567820', 'Jl. Diponegoro No. 29, Bandung', '2022-05-05'),
    (21, 'MRN-0021', 'Bayu Aji', '2020-04-19', 'male', '081234567821', 'Jl. Diponegoro No. 1, Bandung', '2025-08-31'),
    (22, 'MRN-0022', 'Hendra Saputra', '1958-01-28', 'male', '081234567822', 'Jl. Pahlawan No. 10, Makassar', '2019-01-18'),
    (23, 'MRN-0023', 'Putri Wijayanti', '1977-09-05', 'female', '081234567823', 'Jl. Anggrek No. 74, Palembang', '2023-01-16'),
    (24, 'MRN-0024', 'Taufik Hidayat', '2002-04-04', 'male', '081234567824', 'Jl. Sudirman No. 85, Bogor', '2021-01-10'),
    (25, 'MRN-0025', 'Diah Puspita', '2009-12-02', 'female', '081234567825', 'Jl. Mawar No. 84, Denpasar', '2016-09-03'),
    (26, 'MRN-0026', 'Yusuf Maulana', '1993-02-08', 'male', '081234567826', 'Jl. Diponegoro No. 25, Makassar', '2022-08-19'),
    (27, 'MRN-0027', 'Hadi Susanto', '1973-05-15', 'male', '081234567827', 'Jl. Diponegoro No. 10, Medan', '2024-05-12'),
    (28, 'MRN-0028', 'Bambang Setiawan', '2019-01-03', 'male', '081234567828', 'Jl. Flamboyan No. 97, Depok', '2021-01-06'),
    (29, 'MRN-0029', 'Hadi Susanto', '2012-08-07', 'male', '081234567829', 'Jl. Kenanga No. 52, Jakarta', '2017-10-20'),
    (30, 'MRN-0030', 'Sri Wahyuni', '1999-05-26', 'female', '081234567830', 'Jl. Cendana No. 59, Yogyakarta', '2022-03-13'),
    (31, 'MRN-0031', 'Fitriani', '1974-05-07', 'female', '081234567831', 'Jl. Merdeka No. 75, Solo', '2024-03-23'),
    (32, 'MRN-0032', 'Eko Purnomo', '1957-01-19', 'male', '081234567832', 'Jl. Kartini No. 65, Depok', '2024-01-14'),
    (33, 'MRN-0033', 'Bambang Setiawan', '2015-02-28', 'male', '081234567833', 'Jl. Gatot Subroto No. 9, Palembang', '2016-04-25'),
    (34, 'MRN-0034', 'Yusuf Maulana', '1965-10-08', 'male', '081234567834', 'Jl. Melati No. 77, Jakarta', '2025-07-15'),
    (35, 'MRN-0035', 'Hadi Susanto', '2016-06-09', 'male', '081234567835', 'Jl. Diponegoro No. 86, Solo', '2021-10-13'),
    (36, 'MRN-0036', 'Fajar Nugroho', '2000-03-22', 'male', '081234567836', 'Jl. Mawar No. 39, Medan', '2020-05-18'),
    (37, 'MRN-0037', 'Ahmad Fauzi', '2008-10-19', 'male', '081234567837', 'Jl. Sudirman No. 10, Makassar', '2018-08-17'),
    (38, 'MRN-0038', 'Fitriani', '1994-02-08', 'female', '081234567838', 'Jl. Pahlawan No. 37, Surabaya', '2022-06-15'),
    (39, 'MRN-0039', 'Rahma Wati', '2017-01-22', 'female', '081234567839', 'Jl. Kenanga No. 71, Yogyakarta', '2018-10-27'),
    (40, 'MRN-0040', 'Fajar Nugroho', '1964-02-24', 'male', '081234567840', 'Jl. Cendrawasih No. 20, Yogyakarta', '2019-10-17');

-- 4. appointments
INSERT INTO appointments (appointment_id, patient_id, provider_id, scheduled_at, status, reason) VALUES
    (1, 39, 4, '2026-05-18 11:52', 'completed', 'Sakit perut'),
    (2, 33, 8, '2026-04-12 20:37', 'completed', 'Demam berkepanjangan'),
    (3, 28, 14, '2026-04-22 18:50', 'completed', 'Nyeri dada'),
    (4, 22, 13, '2026-02-25 03:19', 'completed', 'MRI kepala'),
    (5, 29, 9, '2026-06-20 10:19', 'cancelled', 'Nyeri dada'),
    (6, 8, 2, '2026-03-04 05:17', 'cancelled', 'Kontrol jantung'),
    (7, 24, 10, '2026-03-03 20:20', 'completed', 'Sesak napas'),
    (8, 3, 5, '2026-05-26 22:47', 'completed', 'Nyeri sendi'),
    (9, 14, 11, '2026-04-12 05:47', 'completed', 'Nyeri sendi'),
    (10, 36, 15, '2026-06-12 03:42', 'confirmed', 'Sesak napas'),
    (11, 16, 14, '2026-03-09 10:37', 'completed', 'Kontrol diabetes'),
    (12, 2, 3, '2026-05-14 08:11', 'completed', 'Vaksinasi anak'),
    (13, 18, 3, '2026-02-16 07:31', 'completed', 'Kontrol jantung'),
    (14, 31, 4, '2026-03-23 20:09', 'no_show', 'Nyeri sendi'),
    (15, 20, 14, '2026-04-03 17:20', 'completed', 'Nyeri dada'),
    (16, 13, 7, '2026-05-12 19:37', 'completed', 'Demam berkepanjangan'),
    (17, 18, 6, '2026-07-22 04:00', 'completed', 'Nyeri punggung'),
    (18, 22, 1, '2026-02-19 03:03', 'completed', 'MRI kepala'),
    (19, 38, 5, '2026-01-20 04:34', 'completed', 'Konsultasi umum'),
    (20, 28, 6, '2026-05-07 03:41', 'completed', 'Konsultasi umum'),
    (21, 33, 2, '2026-06-03 22:16', 'scheduled', 'Cek kesehatan tahunan'),
    (22, 17, 1, '2026-06-23 16:21', 'completed', 'Kontrol asma'),
    (23, 35, 11, '2026-03-22 20:30', 'completed', 'Kontrol diabetes'),
    (24, 5, 11, '2026-05-13 13:41', 'confirmed', 'Kontrol jantung lanjutan'),
    (25, 8, 12, '2026-05-01 23:12', 'cancelled', 'Follow-up nyeri dada'),
    (26, 27, 6, '2026-06-10 14:38', 'completed', 'Nyeri punggung'),
    (27, 9, 4, '2026-06-17 14:50', 'completed', 'MRI kepala'),
    (28, 40, 10, '2026-05-02 05:03', 'completed', 'Nyeri punggung'),
    (29, 1, 5, '2026-04-26 18:13', 'completed', 'Kontrol diabetes'),
    (30, 38, 10, '2026-05-10 11:34', 'no_show', 'Sakit kepala'),
    (31, 29, 11, '2026-03-29 07:50', 'cancelled', 'Cek tekanan darah'),
    (32, 11, 11, '2026-02-07 06:21', 'completed', 'Kontrol asma'),
    (33, 40, 6, '2026-02-10 14:25', 'completed', 'Follow-up nyeri dada'),
    (34, 15, 13, '2026-03-23 16:01', 'completed', 'Nyeri dada'),
    (35, 3, 4, '2026-07-08 20:35', 'confirmed', 'Demam berkepanjangan'),
    (36, 30, 7, '2026-03-21 20:16', 'completed', 'Cek tekanan darah'),
    (37, 26, 4, '2026-03-03 15:27', 'completed', 'Imunisasi rutin'),
    (38, 28, 4, '2026-03-14 15:22', 'cancelled', 'Sakit kepala'),
    (39, 4, 9, '2026-04-12 02:41', 'completed', 'Sakit kepala'),
    (40, 9, 13, '2026-07-04 18:47', 'cancelled', 'Nyeri punggung'),
    (41, 39, 6, '2026-06-26 05:04', 'confirmed', 'Kontrol asma'),
    (42, 28, 14, '2026-06-27 12:12', 'completed', 'Cek tekanan darah'),
    (43, 29, 5, '2026-04-11 08:26', 'completed', 'Kontrol asma'),
    (44, 32, 11, '2026-04-08 05:55', 'completed', 'Sakit kepala'),
    (45, 5, 12, '2026-04-26 07:10', 'completed', 'Sakit perut'),
    (46, 22, 6, '2026-02-05 15:02', 'completed', 'Sesak napas'),
    (47, 15, 7, '2026-03-05 16:14', 'completed', 'Demam berkepanjangan'),
    (48, 27, 7, '2026-05-13 20:02', 'cancelled', 'Sakit kepala'),
    (49, 27, 1, '2026-03-26 15:50', 'completed', 'Batuk pilek'),
    (50, 38, 12, '2026-01-12 22:03', 'scheduled', 'Batuk pilek'),
    (51, 31, 1, '2026-05-21 22:37', 'completed', 'Batuk pilek'),
    (52, 27, 9, '2026-03-31 23:34', 'no_show', 'Vaksinasi anak'),
    (53, 18, 7, '2026-07-12 22:30', 'completed', 'Batuk pilek'),
    (54, 22, 11, '2026-06-11 08:30', 'completed', 'Sakit kepala'),
    (55, 9, 10, '2026-01-15 19:20', 'completed', 'Pusing'),
    (56, 37, 11, '2026-01-15 20:36', 'completed', 'Kontrol diabetes'),
    (57, 9, 14, '2026-07-03 15:20', 'completed', 'Kontrol jantung'),
    (58, 17, 7, '2026-05-12 11:08', 'completed', 'Sakit kepala'),
    (59, 21, 6, '2026-06-01 13:42', 'completed', 'Kontrol diabetes'),
    (60, 17, 14, '2026-02-06 03:25', 'no_show', 'Nyeri dada');

-- 5. encounters (from completed appointments, plus emergency walk-ins)
INSERT INTO encounters (encounter_id, patient_id, provider_id, department_id, appointment_id, encounter_type, admitted_at, discharged_at) VALUES
    (1, 39, 4, 4, 1, 'outpatient', '2026-05-18 12:00', '2026-05-18 12:21'),
    (2, 33, 8, 3, 2, 'outpatient', '2026-04-12 20:42', '2026-04-12 21:25'),
    (3, 28, 14, 4, 3, 'outpatient', '2026-04-22 19:00', '2026-04-22 19:23'),
    (4, 22, 13, 3, 4, 'outpatient', '2026-02-25 03:29', '2026-02-25 03:49'),
    (5, 24, 10, 5, 7, 'outpatient', '2026-03-03 20:20', '2026-03-03 21:06'),
    (6, 3, 5, 5, 8, 'outpatient', '2026-05-26 22:50', '2026-05-26 23:07'),
    (7, 14, 11, 1, 9, 'outpatient', '2026-04-12 05:56', '2026-04-12 06:30'),
    (8, 16, 14, 4, 11, 'outpatient', '2026-03-09 10:40', '2026-03-09 11:11'),
    (9, 2, 3, 3, 12, 'outpatient', '2026-05-14 08:18', '2026-05-14 08:47'),
    (10, 18, 3, 3, 13, 'outpatient', '2026-02-16 07:40', '2026-02-16 08:22'),
    (11, 20, 14, 4, 15, 'outpatient', '2026-04-03 17:27', '2026-04-03 18:14'),
    (12, 13, 7, 2, 16, 'outpatient', '2026-05-12 19:42', '2026-05-12 20:18'),
    (13, 18, 6, 1, 17, 'outpatient', '2026-07-22 04:09', '2026-07-22 04:38'),
    (14, 22, 1, 1, 18, 'outpatient', '2026-02-19 03:05', '2026-02-19 03:59'),
    (15, 38, 5, 5, 19, 'outpatient', '2026-01-20 04:35', '2026-01-20 06:04'),
    (16, 28, 6, 1, 20, 'outpatient', '2026-05-07 03:41', '2026-05-07 04:35'),
    (17, 17, 1, 1, 22, 'outpatient', '2026-06-23 16:30', '2026-06-23 17:33'),
    (18, 35, 11, 1, 23, 'outpatient', '2026-03-22 20:36', '2026-03-22 21:16'),
    (19, 27, 6, 1, 26, 'outpatient', '2026-06-10 14:39', '2026-06-10 16:09'),
    (20, 9, 4, 4, 27, 'outpatient', '2026-06-17 15:00', '2026-06-17 15:46'),
    (21, 40, 10, 5, 28, 'outpatient', '2026-05-02 05:04', '2026-05-02 05:57'),
    (22, 1, 5, 5, 29, 'outpatient', '2026-04-26 18:23', '2026-04-26 18:53'),
    (23, 11, 11, 1, 32, 'outpatient', '2026-02-07 06:30', '2026-02-07 06:50'),
    (24, 40, 6, 1, 33, 'outpatient', '2026-02-10 14:30', '2026-02-10 15:53'),
    (25, 15, 13, 3, 34, 'outpatient', '2026-03-23 16:07', '2026-03-23 17:09'),
    (26, 30, 7, 2, 36, 'outpatient', '2026-03-21 20:17', '2026-03-21 21:36'),
    (27, 26, 4, 4, 37, 'outpatient', '2026-03-03 15:37', '2026-03-03 16:35'),
    (28, 4, 9, 4, 39, 'outpatient', '2026-04-12 02:41', '2026-04-12 03:49'),
    (29, 28, 14, 4, 42, 'outpatient', '2026-06-27 12:19', '2026-06-27 12:47'),
    (30, 29, 5, 5, 43, 'outpatient', '2026-04-11 08:32', '2026-04-11 09:33'),
    (31, 32, 11, 1, 44, 'outpatient', '2026-04-08 06:05', '2026-04-08 07:18'),
    (32, 5, 12, 2, 45, 'outpatient', '2026-04-26 07:12', '2026-04-26 08:22'),
    (33, 22, 6, 1, 46, 'outpatient', '2026-02-05 15:04', '2026-02-05 16:25'),
    (34, 15, 7, 2, 47, 'outpatient', '2026-03-05 16:24', '2026-03-05 17:13'),
    (35, 27, 1, 1, 49, 'outpatient', '2026-03-26 15:59', '2026-03-26 17:22'),
    (36, 31, 1, 1, 51, 'outpatient', '2026-05-21 22:44', '2026-05-21 23:58'),
    (37, 18, 7, 2, 53, 'outpatient', '2026-07-12 22:36', '2026-07-13 00:06'),
    (38, 22, 11, 1, 54, 'outpatient', '2026-06-11 08:34', '2026-06-11 09:30'),
    (39, 9, 10, 5, 55, 'outpatient', '2026-01-15 19:23', '2026-01-15 19:49'),
    (40, 37, 11, 1, 56, 'outpatient', '2026-01-15 20:40', '2026-01-15 21:52'),
    (41, 9, 14, 4, 57, 'outpatient', '2026-07-03 15:23', '2026-07-03 16:37'),
    (42, 17, 7, 2, 58, 'outpatient', '2026-05-12 11:17', '2026-05-12 12:20'),
    (43, 21, 6, 1, 59, 'outpatient', '2026-06-01 13:47', '2026-06-01 14:05'),
    (44, 32, 8, 3, NULL, 'emergency', '2026-03-16 22:52', '2026-03-17 03:52'),
    (45, 14, 8, 3, NULL, 'emergency', '2026-04-15 16:01', '2026-04-15 20:01'),
    (46, 18, 13, 3, NULL, 'emergency', '2026-04-22 15:00', '2026-04-22 21:00'),
    (47, 1, 13, 3, NULL, 'emergency', '2026-03-20 12:46', '2026-03-20 14:46'),
    (48, 16, 13, 3, NULL, 'emergency', '2026-06-12 04:11', '2026-06-12 09:11'),
    (49, 36, 3, 3, NULL, 'emergency', '2026-07-09 05:30', '2026-07-09 10:30'),
    (50, 29, 3, 3, NULL, 'emergency', '2026-02-10 11:19', '2026-02-10 15:19'),
    (51, 15, 8, 3, NULL, 'emergency', '2026-04-09 19:46', '2026-04-09 23:46'),
    (52, 38, 8, 3, NULL, 'emergency', '2026-07-08 03:06', '2026-07-08 09:06'),
    (53, 34, 8, 3, NULL, 'emergency', '2026-06-19 13:58', '2026-06-19 19:58'),
    (54, 22, 8, 3, NULL, 'emergency', '2026-06-30 13:12', '2026-06-30 17:12'),
    (55, 20, 8, 3, NULL, 'emergency', '2026-04-04 20:46', '2026-04-04 22:46');

-- 6. diagnoses
INSERT INTO diagnoses (diagnosis_id, encounter_id, icd10_code, description, diagnosed_at, is_primary) VALUES
    (1, 1, 'I10', 'Essential (primary) hypertension', '2026-05-18 12:13', true),
    (2, 2, 'Z00.00', 'General medical examination', '2026-04-12 20:58', true),
    (3, 3, 'K29.70', 'Gastritis, unspecified', '2026-04-22 19:29', true),
    (4, 3, 'J06.9', 'Acute upper respiratory infection, unspecified', '2026-04-22 19:19', false),
    (5, 4, 'Z00.00', 'General medical examination', '2026-02-25 03:48', true),
    (6, 5, 'A09', 'Infectious gastroenteritis', '2026-03-03 20:35', true),
    (7, 6, 'I20.9', 'Angina pectoris, unspecified', '2026-05-26 23:22', true),
    (8, 7, 'K29.70', 'Gastritis, unspecified', '2026-04-12 06:07', true),
    (9, 8, 'L20.9', 'Atopic dermatitis, unspecified', '2026-03-09 10:59', true),
    (10, 9, 'M54.5', 'Low back pain', '2026-05-14 08:31', true),
    (11, 10, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-02-16 08:05', true),
    (12, 11, 'K21.9', 'Gastro-esophageal reflux disease without esophagitis', '2026-04-03 17:42', true),
    (13, 11, 'I10', 'Essential (primary) hypertension', '2026-04-03 18:07', false),
    (14, 12, 'K29.70', 'Gastritis, unspecified', '2026-05-12 20:22', true),
    (15, 13, 'R50.9', 'Fever, unspecified', '2026-07-22 04:31', true),
    (16, 13, 'I25.10', 'Atherosclerotic heart disease', '2026-07-22 04:34', false),
    (17, 14, 'E78.5', 'Hyperlipidemia, unspecified', '2026-02-19 03:19', true),
    (18, 15, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-01-20 04:47', true),
    (19, 16, 'R50.9', 'Fever, unspecified', '2026-05-07 04:08', true),
    (20, 17, 'Z23', 'Encounter for immunization', '2026-06-23 16:52', true),
    (21, 17, 'J06.9', 'Acute upper respiratory infection, unspecified', '2026-06-23 16:54', false),
    (22, 18, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-03-22 20:55', true),
    (23, 18, 'N18.9', 'Chronic kidney disease, unspecified', '2026-03-22 21:04', false),
    (24, 19, 'R50.9', 'Fever, unspecified', '2026-06-10 15:19', true),
    (25, 20, 'Z00.00', 'General medical examination', '2026-06-17 15:18', true),
    (26, 21, 'R51', 'Headache', '2026-05-02 05:21', true),
    (27, 22, 'L20.9', 'Atopic dermatitis, unspecified', '2026-04-26 18:35', true),
    (28, 23, 'I20.9', 'Angina pectoris, unspecified', '2026-02-07 06:53', true),
    (29, 24, 'M54.5', 'Low back pain', '2026-02-10 14:41', true),
    (30, 24, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-02-10 14:47', false),
    (31, 25, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-03-23 16:39', true),
    (32, 26, 'I25.10', 'Atherosclerotic heart disease', '2026-03-21 20:56', true),
    (33, 26, 'Z23', 'Encounter for immunization', '2026-03-21 20:35', false),
    (34, 27, 'N18.9', 'Chronic kidney disease, unspecified', '2026-03-03 15:50', true),
    (35, 28, 'J45.909', 'Asthma, unspecified', '2026-04-12 03:20', true),
    (36, 29, 'J45.909', 'Asthma, unspecified', '2026-06-27 12:31', true),
    (37, 30, 'R51', 'Headache', '2026-04-11 09:07', true),
    (38, 31, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-04-08 06:29', true),
    (39, 32, 'K21.9', 'Gastro-esophageal reflux disease without esophagitis', '2026-04-26 07:44', true),
    (40, 33, 'E11.9', 'Type 2 diabetes mellitus without complications', '2026-02-05 15:44', true),
    (41, 34, 'J06.9', 'Acute upper respiratory infection, unspecified', '2026-03-05 16:51', true),
    (42, 35, 'K21.9', 'Gastro-esophageal reflux disease without esophagitis', '2026-03-26 16:28', true),
    (43, 35, 'I25.10', 'Atherosclerotic heart disease', '2026-03-26 16:10', false),
    (44, 36, 'I10', 'Essential (primary) hypertension', '2026-05-21 22:54', true),
    (45, 36, 'K29.70', 'Gastritis, unspecified', '2026-05-21 22:56', false),
    (46, 37, 'I20.9', 'Angina pectoris, unspecified', '2026-07-12 23:10', true),
    (47, 38, 'E78.5', 'Hyperlipidemia, unspecified', '2026-06-11 09:08', true),
    (48, 39, 'M54.5', 'Low back pain', '2026-01-15 19:49', true),
    (49, 40, 'K29.70', 'Gastritis, unspecified', '2026-01-15 21:08', true),
    (50, 40, 'R51', 'Headache', '2026-01-15 21:03', false),
    (51, 41, 'I25.10', 'Atherosclerotic heart disease', '2026-07-03 15:44', true),
    (52, 41, 'M54.5', 'Low back pain', '2026-07-03 15:46', false),
    (53, 42, 'I10', 'Essential (primary) hypertension', '2026-05-12 11:48', true),
    (54, 43, 'R51', 'Headache', '2026-06-01 14:07', true),
    (55, 44, 'M54.5', 'Low back pain', '2026-03-16 23:23', true),
    (56, 44, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-03-16 23:32', false),
    (57, 45, 'L20.9', 'Atopic dermatitis, unspecified', '2026-04-15 16:25', true),
    (58, 45, 'E78.5', 'Hyperlipidemia, unspecified', '2026-04-15 16:13', false),
    (59, 46, 'K29.70', 'Gastritis, unspecified', '2026-04-22 15:20', true),
    (60, 47, 'E11.9', 'Type 2 diabetes mellitus without complications', '2026-03-20 13:23', true),
    (61, 48, 'L20.9', 'Atopic dermatitis, unspecified', '2026-06-12 04:35', true),
    (62, 49, 'E78.5', 'Hyperlipidemia, unspecified', '2026-07-09 05:56', true),
    (63, 49, 'Z00.00', 'General medical examination', '2026-07-09 05:51', false),
    (64, 50, 'K21.9', 'Gastro-esophageal reflux disease without esophagitis', '2026-02-10 11:35', true),
    (65, 50, 'E78.5', 'Hyperlipidemia, unspecified', '2026-02-10 11:37', false),
    (66, 51, 'I21.9', 'Acute myocardial infarction, unspecified', '2026-04-09 20:10', true),
    (67, 52, 'R50.9', 'Fever, unspecified', '2026-07-08 03:36', true),
    (68, 52, 'I20.9', 'Angina pectoris, unspecified', '2026-07-08 03:35', false),
    (69, 53, 'R51', 'Headache', '2026-06-19 14:17', true),
    (70, 54, 'L20.9', 'Atopic dermatitis, unspecified', '2026-06-30 13:35', true),
    (71, 55, 'Z23', 'Encounter for immunization', '2026-04-04 21:22', true);

-- 7. procedures
INSERT INTO procedures (procedure_id, encounter_id, cpt_code, description, performed_by, performed_at) VALUES
    (1, 2, '93306', 'Echocardiogram, complete', 8, '2026-04-12 21:07'),
    (2, 4, '43235', 'Upper GI endoscopy, diagnostic', 13, '2026-02-25 03:50'),
    (3, 6, '87081', 'Stool culture', 5, '2026-05-26 23:10'),
    (4, 7, '71046', 'Chest X-ray, 2 views', 11, '2026-04-12 06:05'),
    (5, 8, '99213', 'Office visit, established patient', 14, '2026-03-09 11:01'),
    (6, 10, '93306', 'Echocardiogram, complete', 3, '2026-02-16 07:53'),
    (7, 13, '71046', 'Chest X-ray, 2 views', 6, '2026-07-22 04:22'),
    (8, 15, '43235', 'Upper GI endoscopy, diagnostic', 5, '2026-01-20 04:58'),
    (9, 19, '87081', 'Stool culture', 6, '2026-06-10 14:55'),
    (10, 20, '71046', 'Chest X-ray, 2 views', 4, '2026-06-17 15:17'),
    (11, 21, '93010', 'ECG interpretation and report', 10, '2026-05-02 05:15'),
    (12, 23, '92941', 'Percutaneous coronary intervention', 11, '2026-02-07 06:42'),
    (13, 25, '93010', 'ECG interpretation and report', 13, '2026-03-23 16:35'),
    (14, 26, '92941', 'Percutaneous coronary intervention', 7, '2026-03-21 20:34'),
    (15, 30, '93000', 'Electrocardiogram, routine', 5, '2026-04-11 08:41'),
    (16, 31, '99213', 'Office visit, established patient', 11, '2026-04-08 06:20'),
    (17, 34, '71046', 'Chest X-ray, 2 views', 7, '2026-03-05 16:43'),
    (18, 35, '70551', 'MRI brain without contrast', 1, '2026-03-26 16:17'),
    (19, 38, '43235', 'Upper GI endoscopy, diagnostic', 11, '2026-06-11 08:49'),
    (20, 40, '93306', 'Echocardiogram, complete', 11, '2026-01-15 20:55'),
    (21, 43, '93010', 'ECG interpretation and report', 6, '2026-06-01 14:12'),
    (22, 47, '93306', 'Echocardiogram, complete', 13, '2026-03-20 12:58'),
    (23, 52, '93306', 'Echocardiogram, complete', 8, '2026-07-08 03:35'),
    (24, 55, '43235', 'Upper GI endoscopy, diagnostic', 8, '2026-04-04 20:51');

-- 8. medications
INSERT INTO medications (medication_id, name, generic_name, form, strength, is_controlled_substance) VALUES
    (1, 'Paracetamol', 'Paracetamol', 'tablet', '500mg', false),
    (2, 'Amoxicillin', 'Amoxicillin', 'capsule', '500mg', false),
    (3, 'Atorvastatin', 'Atorvastatin', 'tablet', '20mg', false),
    (4, 'Salbutamol Inhaler', 'Salbutamol', 'inhaler', '100mcg', false),
    (5, 'Omeprazole', 'Omeprazole', 'capsule', '20mg', false),
    (6, 'Metformin', 'Metformin', 'tablet', '500mg', false),
    (7, 'Aspirin', 'Acetylsalicylic acid', 'tablet', '80mg', false),
    (8, 'Morphine Sulfate', 'Morphine', 'injection', '10mg/mL', true),
    (9, 'Ceftriaxone', 'Ceftriaxone', 'injection', '1g', false),
    (10, 'Oralit', 'Oral Rehydration Salts', 'syrup', 'per sachet', false),
    (11, 'Simvastatin', 'Simvastatin', 'tablet', '10mg', false),
    (12, 'Cetirizine', 'Cetirizine', 'tablet', '10mg', false),
    (13, 'Ibuprofen', 'Ibuprofen', 'tablet', '400mg', false),
    (14, 'Ranitidine', 'Ranitidine', 'injection', '50mg/2mL', false),
    (15, 'Fentanyl', 'Fentanyl citrate', 'injection', '50mcg/mL', true);

-- 9. prescriptions
INSERT INTO prescriptions (prescription_id, encounter_id, medication_id, prescribed_by, dosage, frequency, duration_days, prescribed_at) VALUES
    (1, 1, 5, 4, '20mg', 'saat perlu', 14, '2026-05-18 12:26'),
    (2, 2, 7, 8, '80mg', '3x sehari', 5, '2026-04-12 21:18'),
    (3, 2, 10, 8, 'per sachet', '2x sehari', 30, '2026-04-12 21:02'),
    (4, 4, 8, 13, '10mg/mL', 'tiap BAB cair', 5, '2026-02-25 04:13'),
    (5, 5, 5, 10, '20mg', '1x sehari', 14, '2026-03-03 20:43'),
    (6, 5, 8, 10, '10mg/mL', '1x sehari sebelum makan', 30, '2026-03-03 21:03'),
    (7, 6, 6, 5, '500mg', '1x sehari sebelum makan', 14, '2026-05-26 23:23'),
    (8, 7, 14, 11, '50mg/2mL', '1x sehari malam', 14, '2026-04-12 06:20'),
    (9, 9, 10, 3, 'per sachet', 'tiap BAB cair', 7, '2026-05-14 08:44'),
    (10, 11, 7, 14, '80mg', 'tiap BAB cair', 3, '2026-04-03 17:42'),
    (11, 11, 5, 14, '20mg', 'tiap BAB cair', 14, '2026-04-03 18:11'),
    (12, 15, 4, 5, '100mcg', '1x sehari malam', 30, '2026-01-20 05:10'),
    (13, 16, 13, 6, '400mg', '3x sehari', 3, '2026-05-07 04:17'),
    (14, 16, 11, 6, '10mg', '1x sehari', 7, '2026-05-07 04:24'),
    (15, 18, 12, 11, '10mg', '2x sehari', 7, '2026-03-22 20:55'),
    (16, 19, 3, 6, '20mg', '3x sehari', 30, '2026-06-10 15:00'),
    (17, 21, 15, 10, '50mcg/mL', '3x sehari', 7, '2026-05-02 05:45'),
    (18, 21, 5, 10, '20mg', '1x, loading dose', 7, '2026-05-02 05:48'),
    (19, 22, 13, 5, '400mg', '1x, loading dose', 3, '2026-04-26 18:41'),
    (20, 23, 14, 11, '50mg/2mL', 'sekali, IV', 30, '2026-02-07 07:06'),
    (21, 24, 1, 6, '500mg', '1x sehari, IV', 3, '2026-02-10 14:53'),
    (22, 25, 12, 13, '10mg', 'tiap BAB cair', 14, '2026-03-23 16:30'),
    (23, 25, 11, 13, '10mg', 'saat perlu', 3, '2026-03-23 16:48'),
    (24, 26, 1, 7, '500mg', '1x sehari, IV', 7, '2026-03-21 20:51'),
    (25, 28, 11, 9, '10mg', '1x, loading dose', 7, '2026-04-12 03:22'),
    (26, 29, 3, 14, '20mg', '1x sehari', 7, '2026-06-27 12:35'),
    (27, 31, 15, 11, '50mcg/mL', '3x sehari', 14, '2026-04-08 06:37'),
    (28, 32, 12, 12, '10mg', '1x sehari, IV', 14, '2026-04-26 07:57'),
    (29, 32, 15, 12, '50mcg/mL', '3x sehari', 14, '2026-04-26 07:45'),
    (30, 33, 10, 6, 'per sachet', '1x sehari sebelum makan', 3, '2026-02-05 15:32'),
    (31, 34, 8, 7, '10mg/mL', '1x sehari malam', 7, '2026-03-05 16:53'),
    (32, 35, 6, 1, '500mg', 'saat perlu', 3, '2026-03-26 16:42'),
    (33, 35, 9, 1, '1g', '1x sehari sebelum makan', 5, '2026-03-26 16:26'),
    (34, 39, 11, 10, '10mg', 'tiap BAB cair', 3, '2026-01-15 19:58'),
    (35, 40, 4, 11, '100mcg', 'tiap BAB cair', 5, '2026-01-15 20:59'),
    (36, 41, 4, 14, '100mcg', '1x sehari malam', 7, '2026-07-03 15:44'),
    (37, 41, 10, 14, 'per sachet', '3x sehari', 30, '2026-07-03 16:02'),
    (38, 42, 3, 7, '20mg', '1x sehari sebelum makan', 5, '2026-05-12 11:49'),
    (39, 43, 3, 6, '20mg', 'saat perlu', 5, '2026-06-01 14:02'),
    (40, 44, 3, 8, '20mg', '1x sehari', 5, '2026-03-16 23:15'),
    (41, 45, 2, 8, '500mg', '1x, loading dose', 14, '2026-04-15 16:18'),
    (42, 45, 12, 8, '10mg', 'saat perlu', 30, '2026-04-15 16:40'),
    (43, 46, 9, 13, '1g', 'tiap BAB cair', 3, '2026-04-22 15:22'),
    (44, 47, 9, 13, '1g', '1x sehari', 3, '2026-03-20 13:15'),
    (45, 47, 5, 13, '20mg', 'sekali, IV', 14, '2026-03-20 13:16'),
    (46, 48, 12, 13, '10mg', '1x, loading dose', 3, '2026-06-12 04:55'),
    (47, 50, 2, 3, '500mg', '1x sehari sebelum makan', 30, '2026-02-10 11:38'),
    (48, 51, 12, 8, '10mg', 'tiap BAB cair', 30, '2026-04-09 20:13'),
    (49, 51, 6, 8, '500mg', '1x, loading dose', 30, '2026-04-09 20:10'),
    (50, 52, 13, 8, '400mg', '2x sehari', 30, '2026-07-08 03:43'),
    (51, 53, 7, 8, '80mg', '1x sehari malam', 14, '2026-06-19 14:27'),
    (52, 54, 7, 8, '80mg', '2x sehari', 7, '2026-06-30 13:40'),
    (53, 55, 5, 8, '20mg', '3x sehari', 14, '2026-04-04 21:31'),
    (54, 55, 6, 8, '500mg', '2x sehari', 3, '2026-04-04 21:03');

-- 10. lab_orders
INSERT INTO lab_orders (lab_order_id, encounter_id, test_type, ordered_by, ordered_at, status) VALUES
    (1, 1, 'Troponin', 4, '2026-05-18 12:13', 'resulted'),
    (2, 5, 'Troponin', 10, '2026-03-03 20:35', 'resulted'),
    (3, 12, 'Electrolyte Panel', 7, '2026-05-12 20:00', 'resulted'),
    (4, 14, 'Troponin', 1, '2026-02-19 03:18', 'resulted'),
    (5, 15, 'Liver Function Test', 5, '2026-01-20 04:55', 'resulted'),
    (6, 16, 'Thyroid Panel (TSH)', 6, '2026-05-07 04:00', 'resulted'),
    (7, 19, 'Complete Blood Count (CBC)', 6, '2026-06-10 14:49', 'resulted'),
    (8, 20, 'Stool Routine', 4, '2026-06-17 15:13', 'resulted'),
    (9, 23, 'Complete Blood Count (CBC)', 11, '2026-02-07 06:32', 'resulted'),
    (10, 24, 'HbA1c', 6, '2026-02-10 14:45', 'resulted'),
    (11, 25, 'Liver Function Test', 13, '2026-03-23 16:19', 'resulted'),
    (12, 27, 'Lipid Panel', 4, '2026-03-03 15:43', 'resulted'),
    (13, 30, 'HbA1c', 5, '2026-04-11 08:49', 'resulted'),
    (14, 31, 'Spirometry', 11, '2026-04-08 06:23', 'resulted'),
    (15, 32, 'Liver Function Test', 12, '2026-04-26 07:32', 'resulted'),
    (16, 34, 'HbA1c', 7, '2026-03-05 16:27', 'resulted'),
    (17, 35, 'Spirometry', 1, '2026-03-26 16:05', 'resulted'),
    (18, 36, 'Troponin', 1, '2026-05-21 22:46', 'resulted'),
    (19, 37, 'Complete Blood Count (CBC)', 7, '2026-07-12 22:50', 'resulted'),
    (20, 38, 'Thyroid Panel (TSH)', 11, '2026-06-11 08:47', 'resulted'),
    --(21, 40, 'Lipid Panel', 11, '2026-01-15 20:56', 'pending'),
    (22, 45, 'Troponin', 8, '2026-04-15 16:15', 'resulted'),
    (23, 46, 'Electrolyte Panel', 13, '2026-04-22 15:16', 'resulted'),
    (24, 48, 'Troponin', 13, '2026-06-12 04:20', 'resulted'),
  --  (25, 49, 'Troponin', 3, '2026-07-09 05:44', 'pending'),
    (26, 51, 'Complete Blood Count (CBC)', 8, '2026-04-09 19:50', 'resulted'),
  --  (27, 52, 'Thyroid Panel (TSH)', 8, '2026-07-08 03:14', 'pending'),
    (28, 53, 'Complete Blood Count (CBC)', 8, '2026-06-19 14:07', 'resulted'),
    (29, 54, 'Complete Blood Count (CBC)', 8, '2026-06-30 13:18', 'resulted');

-- 11. lab_results (a lab_order can have several result parameters; only 'resulted' orders have results)
INSERT INTO lab_results (lab_result_id, lab_order_id, result_value, unit, reference_range, is_abnormal, resulted_at) VALUES
    (1, 1, 'FEV1 91', '% pred', '>80', true, '2026-05-18 13:32'),
    (2, 2, 'AST 38', 'U/L', '5-40', false, '2026-03-03 21:14'),
    (3, 2, 'WBC 8.7', 'x10^9/L', '4.5-11.0', false, '2026-03-03 21:14'),
    (4, 2, 'ALT 27', 'U/L', '7-56', false, '2026-03-03 21:14'),
    (5, 3, 'ALT 39', 'U/L', '7-56', false, '2026-05-12 20:59'),
    (6, 3, 'LDL 87', 'mg/dL', '<130', false, '2026-05-12 20:59'),
    (7, 4, 'LDL 129', 'mg/dL', '<130', false, '2026-02-19 04:42'),
    (8, 4, 'AST 45', 'U/L', '5-40', true, '2026-02-19 04:42'),
    (9, 5, 'FEV1 75', '% pred', '>80', true, '2026-01-20 05:39'),
    (10, 6, 'Total Cholesterol 163', 'mg/dL', '<200', true, '2026-05-07 05:17'),
    (11, 7, 'LDL 85', 'mg/dL', '<130', false, '2026-06-10 15:31'),
    (12, 7, 'ALT 38', 'U/L', '7-56', true, '2026-06-10 15:31'),
    (13, 8, 'WBC 14.9', 'x10^9/L', '4.5-11.0', false, '2026-06-17 16:20'),
    (14, 9, 'AST 14', 'U/L', '5-40', false, '2026-02-07 07:34'),
    (15, 9, 'Total Cholesterol 221', 'mg/dL', '<200', true, '2026-02-07 07:34'),
    (16, 10, 'Hemoglobin 10.6', 'g/dL', '13.5-17.5', true, '2026-02-10 15:47'),
    (17, 10, 'HDL 47', 'mg/dL', '>40', false, '2026-02-10 15:47'),
    (18, 11, 'HDL 46', 'mg/dL', '>40', true, '2026-03-23 17:27'),
    (19, 11, 'LDL 165', 'mg/dL', '<130', true, '2026-03-23 17:27'),
    (20, 11, 'Hemoglobin 16.6', 'g/dL', '13.5-17.5', true, '2026-03-23 17:27'),
    (21, 12, 'Platelet 285', 'x10^9/L', '150-450', false, '2026-03-03 17:08'),
    (22, 13, 'HDL 56', 'mg/dL', '>40', false, '2026-04-11 09:52'),
    (23, 13, 'Troponin I 3.00', 'ng/mL', '<0.04', false, '2026-04-11 09:52'),
    (24, 14, 'LDL 174', 'mg/dL', '<130', true, '2026-04-08 07:52'),
    (25, 14, 'ALT 12', 'U/L', '7-56', true, '2026-04-08 07:52'),
    (26, 15, 'AST 19', 'U/L', '5-40', false, '2026-04-26 08:40'),
    (27, 16, 'FEV1 81', '% pred', '>80', false, '2026-03-05 16:52'),
    (28, 17, 'FEV1 83', '% pred', '>80', false, '2026-03-26 17:01'),
    (29, 18, 'Hemoglobin 16.3', 'g/dL', '13.5-17.5', false, '2026-05-22 00:06'),
    (30, 19, 'FEV1 88', '% pred', '>80', false, '2026-07-13 00:14'),
    (31, 19, 'Hemoglobin 11.1', 'g/dL', '13.5-17.5', false, '2026-07-13 00:14'),
    (32, 19, 'Platelet 409', 'x10^9/L', '150-450', false, '2026-07-13 00:14'),
    (33, 20, 'Total Cholesterol 220', 'mg/dL', '<200', true, '2026-06-11 09:54'),
    (34, 20, 'FEV1 100', '% pred', '>80', true, '2026-06-11 09:54'),
    (35, 22, 'Hemoglobin 15.3', 'g/dL', '13.5-17.5', false, '2026-04-15 16:45'),
    (36, 23, 'Platelet 213', 'x10^9/L', '150-450', true, '2026-04-22 15:47'),
    (37, 24, 'Total Cholesterol 200', 'mg/dL', '<200', false, '2026-06-12 04:46'),
    (38, 24, 'Platelet 220', 'x10^9/L', '150-450', false, '2026-06-12 04:46'),
    (39, 26, 'WBC 3.4', 'x10^9/L', '4.5-11.0', true, '2026-04-09 20:38'),
    (40, 28, 'HDL 43', 'mg/dL', '>40', true, '2026-06-19 14:31'),
    (41, 28, 'AST 40', 'U/L', '5-40', true, '2026-06-19 14:31'),
    (42, 29, 'FEV1 94', '% pred', '>80', false, '2026-06-30 14:35');

-- 12. vitals
INSERT INTO vitals (vital_id, encounter_id, recorded_at, heart_rate, blood_pressure_systolic, blood_pressure_diastolic, temperature_celsius, oxygen_saturation, recorded_by) VALUES
    (1, 1, '2026-05-18 12:02', 62, 111, 73, 39.0, 98, 4),
    (2, 2, '2026-04-12 20:52', 114, 102, 78, 37.1, 91, 8),
    (3, 3, '2026-04-22 19:01', 90, 121, 89, 36.5, 97, 14),
    (4, 4, '2026-02-25 03:39', 62, 135, 92, 38.1, 92, 13),
    (5, 5, '2026-03-03 20:25', 114, 95, 82, 37.1, 96, 10),
    (6, 6, '2026-05-26 22:53', 70, 128, 83, 36.5, 98, 5),
    (7, 7, '2026-04-12 06:05', 124, 145, 92, 38.1, 96, 11),
    (8, 8, '2026-03-09 10:48', 65, 135, 84, 39.4, 94, 14),
    (9, 9, '2026-05-14 08:19', 105, 145, 64, 37.4, 100, 3),
    (10, 10, '2026-02-16 07:42', 102, 103, 62, 37.4, 95, 3),
    (11, 11, '2026-04-03 17:30', 119, 139, 90, 38.3, 92, 14),
    (12, 12, '2026-05-12 19:44', 118, 97, 78, 36.9, 93, 7),
    (13, 13, '2026-07-22 04:10', 100, 154, 79, 37.9, 98, 6),
    (14, 14, '2026-02-19 03:13', 92, 97, 72, 37.2, 90, 1),
    (15, 15, '2026-01-20 04:41', 94, 102, 83, 37.7, 96, 5),
    (16, 16, '2026-05-07 03:49', 109, 116, 71, 37.9, 97, 6),
    (17, 17, '2026-06-23 16:36', 94, 146, 65, 38.6, 91, 1),
    (18, 18, '2026-03-22 20:43', 83, 129, 78, 37.3, 91, 11),
    (19, 19, '2026-06-10 14:45', 97, 114, 88, 38.2, 96, 6),
    (20, 20, '2026-06-17 15:03', 116, 117, 88, 36.4, 95, 4),
    (21, 21, '2026-05-02 05:14', 115, 112, 63, 36.5, 100, 10),
    (22, 22, '2026-04-26 18:30', 106, 127, 70, 39.3, 92, 5),
    (23, 23, '2026-02-07 06:40', 116, 97, 68, 36.5, 100, 11),
    (24, 24, '2026-02-10 14:36', 106, 119, 96, 36.4, 92, 6),
    (25, 25, '2026-03-23 16:15', 107, 118, 88, 38.7, 99, 13),
    (26, 26, '2026-03-21 20:20', 106, 120, 80, 38.4, 93, 7),
    (27, 27, '2026-03-03 15:39', 63, 142, 71, 37.9, 96, 4),
    (28, 28, '2026-04-12 02:50', 75, 111, 76, 38.6, 93, 9),
    (29, 29, '2026-06-27 12:29', 96, 139, 91, 36.9, 92, 14),
    (30, 30, '2026-04-11 08:34', 117, 106, 88, 39.5, 100, 5),
    (31, 31, '2026-04-08 06:11', 104, 140, 64, 38.1, 94, 11),
    (32, 32, '2026-04-26 07:17', 80, 140, 71, 38.8, 98, 12),
    (33, 33, '2026-02-05 15:08', 75, 107, 68, 37.1, 97, 6),
    (34, 34, '2026-03-05 16:25', 106, 130, 96, 37.5, 98, 7),
    (35, 35, '2026-03-26 16:02', 71, 99, 79, 37.6, 97, 1),
    (36, 36, '2026-05-21 22:53', 112, 144, 86, 38.9, 91, 1),
    (37, 37, '2026-07-12 22:39', 100, 136, 64, 37.7, 100, 7),
    (38, 38, '2026-06-11 08:43', 104, 103, 95, 38.3, 92, 11),
    (39, 39, '2026-01-15 19:26', 115, 127, 63, 39.0, 98, 10),
    (40, 40, '2026-01-15 20:43', 98, 105, 70, 37.3, 93, 11),
    (41, 41, '2026-07-03 15:29', 96, 149, 65, 37.1, 100, 14),
    (42, 42, '2026-05-12 11:26', 95, 103, 79, 38.3, 91, 7),
    (43, 43, '2026-06-01 13:56', 81, 132, 97, 36.8, 100, 6),
    (44, 44, '2026-03-16 23:02', 103, 148, 96, 36.4, 90, 8),
    (45, 45, '2026-04-15 16:03', 65, 155, 96, 37.1, 93, 8),
    (46, 46, '2026-04-22 15:10', 113, 134, 61, 37.9, 100, 13),
    (47, 47, '2026-03-20 12:55', 97, 136, 79, 37.8, 100, 13),
    (48, 48, '2026-06-12 04:18', 98, 124, 64, 38.5, 92, 13),
    (49, 49, '2026-07-09 05:38', 113, 125, 89, 37.0, 99, 3),
    (50, 50, '2026-02-10 11:22', 100, 150, 80, 38.6, 95, 3),
    (51, 51, '2026-04-09 19:53', 76, 143, 83, 37.9, 91, 8),
    (52, 52, '2026-07-08 03:12', 90, 124, 67, 37.2, 93, 8),
    (53, 53, '2026-06-19 14:01', 72, 98, 78, 39.3, 99, 8),
    (54, 54, '2026-06-30 13:19', 91, 150, 70, 38.9, 99, 8),
    (55, 55, '2026-04-04 20:52', 84, 143, 70, 37.9, 98, 8);

-- 13. allergies
INSERT INTO allergies (allergy_id, patient_id, allergen, reaction, severity, recorded_at) VALUES
    (1, 30, 'Susu sapi', 'Diare, kembung', 'mild', '2023-01-28'),
    (2, 30, 'Kacang', 'Bengkak bibir', 'moderate', '2021-03-09'),
    (3, 32, 'Aspirin', 'Perdarahan lambung', 'severe', '2015-07-02'),
    (4, 20, 'Debu', 'Bersin, sesak napas ringan', 'moderate', '2023-05-03'),
    (5, 20, 'Aspirin', 'Perdarahan lambung', 'severe', '2023-08-25'),
    (6, 39, 'Serbuk sari', 'Bersin, mata gatal', 'mild', '2025-10-04'),
    (7, 2, 'Telur', 'Ruam kulit', 'moderate', '2020-06-18'),
    (8, 6, 'Debu', 'Bersin, sesak napas ringan', 'severe', '2024-09-13'),
    (9, 26, 'Penicillin', 'Ruam kulit', 'moderate', '2015-03-23'),
    (10, 33, 'Latex', 'Gatal-gatal, bengkak', 'severe', '2022-03-20'),
    (11, 40, 'Aspirin', 'Perdarahan lambung', 'moderate', '2024-06-06'),
    (12, 31, 'Kacang', 'Bengkak bibir', 'moderate', '2023-09-18'),
    (13, 31, 'Aspirin', 'Perdarahan lambung', 'mild', '2024-05-16'),
    (14, 8, 'Aspirin', 'Perdarahan lambung', 'severe', '2025-02-14'),
    (15, 7, 'Penicillin', 'Ruam kulit', 'severe', '2024-08-09'),
    (16, 19, 'Debu', 'Bersin, sesak napas ringan', 'severe', '2024-08-06'),
    (17, 19, 'Penicillin', 'Ruam kulit', 'moderate', '2025-12-20'),
    (18, 12, 'Debu', 'Bersin, sesak napas ringan', 'mild', '2015-10-23'),
    (19, 36, 'Penicillin', 'Ruam kulit', 'mild', '2022-06-14'),
    (20, 34, 'Debu', 'Bersin, sesak napas ringan', 'severe', '2021-09-25'),
    (21, 10, 'Penicillin', 'Ruam kulit', 'severe', '2017-09-07'),
    (22, 16, 'Susu sapi', 'Diare, kembung', 'mild', '2023-07-11'),
    (23, 38, 'Latex', 'Gatal-gatal, bengkak', 'moderate', '2020-09-12'),
    (24, 21, 'Susu sapi', 'Diare, kembung', 'moderate', '2018-05-18'),
    (25, 21, 'Debu', 'Bersin, sesak napas ringan', 'moderate', '2018-05-25');

-- 14. immunizations
INSERT INTO immunizations (immunization_id, patient_id, vaccine_name, dose_number, administered_at, administered_by, lot_number) VALUES
    (1, 14, 'Influenza', 1, '2025-09-23 12:00', 3, 'LOT-W100'),
    (2, 32, 'Varicella', 2, '2024-01-22 16:00', 4, 'LOT-X101'),
    (3, 32, 'Influenza', 4, '2023-02-14 13:00', 12, 'LOT-Y102'),
    (4, 21, 'Polio', 4, '2023-09-06 14:00', 11, 'LOT-Z103'),
    (5, 31, 'Influenza', 1, '2025-06-10 08:00', 15, 'LOT-A104'),
    (6, 23, 'Varicella', 1, '2023-03-14 10:00', 15, 'LOT-B105'),
    (7, 23, 'Influenza', 1, '2026-08-06 12:00', 15, 'LOT-C106'),
    (8, 18, 'Hepatitis B', 4, '2023-06-10 15:00', 11, 'LOT-D107'),
    (9, 19, 'HPV', 2, '2026-05-07 09:00', 6, 'LOT-E108'),
    (10, 8, 'Pneumococcal', 3, '2024-01-24 13:00', 13, 'LOT-F109'),
    (11, 8, 'Hepatitis B', 4, '2024-03-20 14:00', 14, 'LOT-G110'),
    (12, 25, 'Tetanus', 4, '2026-11-04 10:00', 3, 'LOT-H111'),
    (13, 25, 'MMR', 2, '2025-04-01 12:00', 7, 'LOT-I112'),
    (14, 29, 'Hepatitis B', 3, '2025-05-19 08:00', 5, 'LOT-J113'),
    (15, 13, 'Influenza', 3, '2023-08-10 10:00', 7, 'LOT-K114'),
    (16, 13, 'DPT', 2, '2023-11-10 13:00', 10, 'LOT-L115'),
    (17, 27, 'Polio', 4, '2026-03-15 13:00', 7, 'LOT-M116'),
    (18, 12, 'Influenza', 3, '2023-09-15 16:00', 12, 'LOT-N117'),
    (19, 12, 'Varicella', 2, '2023-10-04 08:00', 14, 'LOT-O118'),
    (20, 39, 'HPV', 1, '2024-06-28 16:00', 8, 'LOT-P119'),
    (21, 39, 'Polio', 4, '2024-12-19 15:00', 2, 'LOT-Q120'),
    (22, 26, 'Pneumococcal', 1, '2024-09-14 15:00', 10, 'LOT-R121'),
    (23, 5, 'Pneumococcal', 2, '2023-07-09 08:00', 12, 'LOT-S122'),
    (24, 5, 'Hepatitis B', 1, '2023-01-14 13:00', 12, 'LOT-T123'),
    (25, 10, 'DPT', 2, '2026-01-10 14:00', 3, 'LOT-U124'),
    (26, 10, 'MMR', 4, '2026-06-13 15:00', 14, 'LOT-V125'),
    (27, 2, 'MMR', 2, '2024-11-28 13:00', 2, 'LOT-W126'),
    (28, 24, 'COVID-19 Booster', 1, '2024-12-08 08:00', 13, 'LOT-X127'),
    (29, 24, 'HPV', 4, '2025-08-22 16:00', 7, 'LOT-Y128'),
    (30, 3, 'Influenza', 1, '2026-06-05 12:00', 4, 'LOT-Z129'),
    (31, 28, 'COVID-19 Booster', 1, '2023-04-07 09:00', 2, 'LOT-A130'),
    (32, 15, 'Varicella', 4, '2023-04-24 08:00', 7, 'LOT-B131'),
    (33, 9, 'HPV', 2, '2024-01-05 16:00', 5, 'LOT-C132'),
    (34, 16, 'Varicella', 2, '2025-04-10 10:00', 11, 'LOT-D133'),
    (35, 16, 'Tetanus', 2, '2026-05-09 08:00', 9, 'LOT-E134');

-- 15. insurance_policies (~75% of patients have coverage; rest self-pay)
INSERT INTO insurance_policies (policy_id, patient_id, payer_name, policy_number, coverage_type, valid_from, valid_until) VALUES
    (1, 28, 'Allianz', 'ALZ-1001', 'Premium', '2020-11-01', '2029-06-01'),
    (2, 36, 'BPJS Kesehatan', 'BPJS-1001', 'Kelas III', '2018-01-01', '2026-02-01'),
    (3, 32, 'Prudential', 'PRU-1001', 'Premium', '2022-04-01', NULL),
    (4, 4, 'Allianz', 'ALZ-1002', 'Standard', '2015-04-01', NULL),
    (5, 23, 'BPJS Kesehatan', 'BPJS-1002', 'Kelas III', '2022-04-01', NULL),
    (6, 25, 'Prudential', 'PRU-1002', 'Standard', '2018-09-01', '2028-07-01'),
    (7, 34, 'AXA Mandiri', 'AXA-1001', 'Standard', '2019-05-01', '2029-08-01'),
    (8, 21, 'BPJS Kesehatan', 'BPJS-1003', 'Kelas III', '2022-06-01', NULL),
    (9, 27, 'Allianz', 'ALZ-1003', 'Standard', '2021-01-01', NULL),
    (10, 14, 'Prudential', 'PRU-1003', 'Premium', '2015-05-01', NULL),
    (11, 5, 'AXA Mandiri', 'AXA-1002', 'Standard', '2017-04-01', '2029-10-01'),
    (12, 10, 'Prudential', 'PRU-1004', 'Standard', '2023-11-01', NULL),
    (13, 13, 'Allianz', 'ALZ-1004', 'Standard', '2022-12-01', NULL),
    (14, 6, 'AXA Mandiri', 'AXA-1003', 'Standard', '2017-12-01', NULL),
    (15, 35, 'Prudential', 'PRU-1005', 'Premium', '2023-08-01', '2026-09-01'),
    (16, 18, 'BPJS Kesehatan', 'BPJS-1004', 'Kelas I', '2015-01-01', NULL),
    (17, 16, 'Prudential', 'PRU-1006', 'Premium', '2017-01-01', '2029-06-01'),
    (18, 8, 'BPJS Kesehatan', 'BPJS-1005', 'Kelas III', '2022-11-01', NULL),
    (19, 39, 'BPJS Kesehatan', 'BPJS-1006', 'Kelas III', '2023-07-01', '2028-09-01'),
    (20, 29, 'Allianz', 'ALZ-1005', 'Premium', '2023-12-01', NULL),
    (21, 30, 'Prudential', 'PRU-1007', 'Premium', '2016-09-01', '2027-10-01'),
    (22, 15, 'Allianz', 'ALZ-1006', 'Standard', '2019-07-01', '2029-08-01'),
    (23, 2, 'Prudential', 'PRU-1008', 'Premium', '2019-11-01', NULL),
    (24, 31, 'BPJS Kesehatan', 'BPJS-1007', 'Kelas III', '2015-02-01', NULL),
    (25, 17, 'AXA Mandiri', 'AXA-1004', 'Standard', '2015-11-01', '2027-02-01'),
    (26, 9, 'AXA Mandiri', 'AXA-1005', 'Standard', '2020-10-01', NULL),
    (27, 19, 'BPJS Kesehatan', 'BPJS-1008', 'Kelas III', '2015-04-01', '2029-05-01'),
    (28, 3, 'BPJS Kesehatan', 'BPJS-1009', 'Kelas I', '2019-09-01', NULL),
    (29, 7, 'BPJS Kesehatan', 'BPJS-1010', 'Kelas I', '2020-01-01', NULL),
    (30, 37, 'Prudential', 'PRU-1009', 'Standard', '2016-05-01', '2027-10-01');
-- Note: remaining ~25% of patients intentionally have no policy
-- -> representing self-pay/uninsured patient cases.

-- 16. claims (only encounters where the patient has an insurance policy)
INSERT INTO claims (claim_id, encounter_id, policy_id, claim_amount, approved_amount, status, submitted_at) VALUES
    (1, 3, 1, 5000000.00, 3268000.00, 'partial', '2026-04-24'),
    (2, 8, 17, 2200000.00, 2200000.00, 'approved', '2026-03-10'),
    (3, 9, 23, 500000.00, 371000.00, 'partial', '2026-05-18'),
    (4, 12, 13, 1500000.00, NULL, 'submitted', '2026-05-16'),
    (5, 13, 16, 5000000.00, 3364000.00, 'partial', '2026-07-26'),
    (6, 16, 1, 12000000.00, 12000000.00, 'approved', '2026-05-09'),
    (7, 18, 15, 800000.00, 628000.00, 'partial', '2026-03-24'),
    (8, 20, 26, 500000.00, 500000.00, 'approved', '2026-06-18'),
    (9, 26, 21, 1500000.00, 1500000.00, 'approved', '2026-03-23'),
    (10, 28, 4, 3500000.00, NULL, 'submitted', '2026-04-16'),
    (11, 29, 1, 500000.00, 361000.00, 'partial', '2026-06-30'),
    (12, 31, 3, 3500000.00, 2841000.00, 'partial', '2026-04-10'),
    (13, 32, 11, 800000.00, 454000.00, 'partial', '2026-04-29'),
    (14, 34, 22, 4000000.00, 4000000.00, 'approved', '2026-03-06'),
    (15, 35, 9, 1500000.00, 930000.00, 'partial', '2026-03-27'),
    (16, 36, 24, 900000.00, NULL, 'submitted', '2026-05-23'),
    (17, 37, 16, 800000.00, 800000.00, 'approved', '2026-07-14'),
    (18, 40, 30, 12000000.00, 9860000.00, 'partial', '2026-01-18'),
    (19, 41, 26, 3500000.00, NULL, 'rejected', '2026-07-05'),
    (20, 42, 25, 12000000.00, 12000000.00, 'approved', '2026-05-16'),
    (21, 43, 8, 3500000.00, 2158000.00, 'partial', '2026-06-05'),
    (22, 46, 16, 1500000.00, 969000.00, 'partial', '2026-04-24'),
    (23, 48, 17, 5000000.00, 5000000.00, 'approved', '2026-06-13'),
    (24, 50, 20, 900000.00, NULL, 'submitted', '2026-02-13'),
    (25, 53, 7, 3500000.00, NULL, 'submitted', '2026-06-21');

-- 17. billing_transactions
INSERT INTO billing_transactions (transaction_id, encounter_id, claim_id, amount, payment_method, paid_at) VALUES
    (1, 1, NULL, 500000.00, 'cash', '2026-05-23'),
    (2, 2, NULL, 2000000.00, 'bank_transfer', '2026-04-12'),
    (3, 3, 1, 2000000.00, 'insurance', '2026-04-26'),
    (4, 4, NULL, 150000.00, 'bank_transfer', '2026-02-27'),
    (5, 5, NULL, 200000.00, 'cash', '2026-03-04'),
    (6, 6, NULL, 350000.00, 'card', '2026-05-31'),
    (7, 7, NULL, 900000.00, 'bank_transfer', '2026-04-15'),
    (8, 8, NULL, 450000.00, 'cash', '2026-03-12'),
    (9, 9, 3, 350000.00, 'insurance', '2026-05-16'),
    (10, 11, NULL, 2000000.00, 'card', '2026-04-03'),
    (11, 12, NULL, 900000.00, 'cash', '2026-05-14'),
    (12, 13, 5, 4000000.00, 'insurance', '2026-07-24'),
    (13, 14, NULL, 4000000.00, 'bank_transfer', '2026-02-21'),
    (14, 15, NULL, 200000.00, 'cash', '2026-01-20'),
    (15, 17, NULL, 450000.00, 'cash', '2026-06-27'),
    (16, 18, NULL, 4000000.00, 'bank_transfer', '2026-03-23'),
    (17, 20, NULL, 2000000.00, 'bank_transfer', '2026-06-17'),
    (18, 21, NULL, 4000000.00, 'cash', '2026-05-06'),
    (19, 22, NULL, 450000.00, 'cash', '2026-04-27'),
    (20, 23, NULL, 200000.00, 'cash', '2026-02-11'),
    (21, 24, NULL, 450000.00, 'card', '2026-02-13'),
    (22, 25, NULL, 900000.00, 'bank_transfer', '2026-03-27'),
    (23, 26, 9, 200000.00, 'insurance', '2026-03-23'),
    (24, 27, NULL, 350000.00, 'bank_transfer', '2026-03-08'),
    (25, 28, NULL, 200000.00, 'card', '2026-04-17'),
    (26, 29, NULL, 200000.00, 'card', '2026-06-28'),
    (27, 30, NULL, 2000000.00, 'cash', '2026-04-14'),
    (28, 31, 12, 2000000.00, 'insurance', '2026-04-09'),
    (29, 32, 13, 350000.00, 'insurance', '2026-04-30'),
    (30, 33, NULL, 350000.00, 'card', '2026-02-06'),
    (31, 34, 14, 150000.00, 'insurance', '2026-03-07'),
    (32, 36, NULL, 2000000.00, 'cash', '2026-05-25'),
    (33, 37, 17, 4000000.00, 'insurance', '2026-07-16'),
    (34, 38, NULL, 4000000.00, 'bank_transfer', '2026-06-12'),
    (35, 39, NULL, 450000.00, 'cash', '2026-01-17'),
    (36, 40, NULL, 350000.00, 'card', '2026-01-18'),
    (37, 41, NULL, 200000.00, 'bank_transfer', '2026-07-07'),
    (38, 42, 20, 900000.00, 'insurance', '2026-05-16'),
    (39, 44, NULL, 450000.00, 'bank_transfer', '2026-03-20'),
    (40, 45, NULL, 500000.00, 'cash', '2026-04-15'),
    (41, 46, 22, 200000.00, 'insurance', '2026-04-25'),
    (42, 48, 23, 450000.00, 'insurance', '2026-06-17'),
    (43, 49, NULL, 2000000.00, 'card', '2026-07-10'),
    (44, 50, NULL, 450000.00, 'cash', '2026-02-10'),
    (45, 51, NULL, 350000.00, 'card', '2026-04-11'),
    (46, 53, NULL, 200000.00, 'card', '2026-06-20');

-- =====================================================================
-- Align each BIGSERIAL sequence with the MAX(id) manually inserted
-- above, so future INSERTs without an explicit id don't collide.
-- =====================================================================
SELECT setval(pg_get_serial_sequence('departments', 'department_id'), (SELECT MAX(department_id) FROM departments));
SELECT setval(pg_get_serial_sequence('providers', 'provider_id'), (SELECT MAX(provider_id) FROM providers));
SELECT setval(pg_get_serial_sequence('patients', 'patient_id'), (SELECT MAX(patient_id) FROM patients));
SELECT setval(pg_get_serial_sequence('appointments', 'appointment_id'), (SELECT MAX(appointment_id) FROM appointments));
SELECT setval(pg_get_serial_sequence('encounters', 'encounter_id'), (SELECT MAX(encounter_id) FROM encounters));
SELECT setval(pg_get_serial_sequence('diagnoses', 'diagnosis_id'), (SELECT MAX(diagnosis_id) FROM diagnoses));
SELECT setval(pg_get_serial_sequence('procedures', 'procedure_id'), (SELECT MAX(procedure_id) FROM procedures));
SELECT setval(pg_get_serial_sequence('medications', 'medication_id'), (SELECT MAX(medication_id) FROM medications));
SELECT setval(pg_get_serial_sequence('prescriptions', 'prescription_id'), (SELECT MAX(prescription_id) FROM prescriptions));
SELECT setval(pg_get_serial_sequence('lab_orders', 'lab_order_id'), (SELECT MAX(lab_order_id) FROM lab_orders));
SELECT setval(pg_get_serial_sequence('lab_results', 'lab_result_id'), (SELECT MAX(lab_result_id) FROM lab_results));
SELECT setval(pg_get_serial_sequence('vitals', 'vital_id'), (SELECT MAX(vital_id) FROM vitals));
SELECT setval(pg_get_serial_sequence('allergies', 'allergy_id'), (SELECT MAX(allergy_id) FROM allergies));
SELECT setval(pg_get_serial_sequence('immunizations', 'immunization_id'), (SELECT MAX(immunization_id) FROM immunizations));
SELECT setval(pg_get_serial_sequence('insurance_policies', 'policy_id'), (SELECT MAX(policy_id) FROM insurance_policies));
SELECT setval(pg_get_serial_sequence('claims', 'claim_id'), (SELECT MAX(claim_id) FROM claims));
SELECT setval(pg_get_serial_sequence('billing_transactions', 'transaction_id'), (SELECT MAX(transaction_id) FROM billing_transactions));


