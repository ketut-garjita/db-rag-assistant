# Schema Notes — Healthcare Data Platform

## Table: patients
Master patient data. Columns: `patient_id` (PK), `mrn` (Medical Record
Number, unique per hospital), `full_name`, `date_of_birth`, `gender`,
`phone`, `address`, `registered_at`, `created_at`, `updated_at`. `mrn` is the primary identifier used
across systems (billing, lab, radiology) — never reuse an inactive MRN.

## Table: providers
Clinical staff data (doctors, nurses, therapists). Columns: `provider_id`
(PK), `full_name`, `specialty`, `license_number`, `department_id` (FK to
departments), `is_active`.

## Table: departments
Hospital units/departments. Columns: `department_id` (PK), `name`
(e.g. Cardiology, Radiology, ER), `location`, `head_provider_id` (FK to
`providers`, the department head).

## Table: appointments
Planned visits (not necessarily realized). Columns: `appointment_id`
(PK), `patient_id` (FK), `provider_id` (FK), `scheduled_at`, `status`
(scheduled/confirmed/cancelled/no_show/completed), `reason`. An appointment whose
status becomes `completed` produces one row in the `encounters` table.

## Table: encounters
Actual visits (outpatient, inpatient, ER). This is the central table
referenced by most other clinical tables. Columns: `encounter_id` (PK),
`patient_id` (FK), `provider_id` (FK), `department_id` (FK),
`encounter_type` (outpatient/inpatient/emergency), `admitted_at`,
`discharged_at`, `appointment_id` (FK, nullable — null for walk-in/ER visits).

## Table: diagnoses
Diagnoses recorded for an encounter, using ICD-10 codes. Columns:
`diagnosis_id` (PK), `encounter_id` (FK), `icd10_code`, `description`,
`diagnosed_at`, `is_primary` (boolean — primary vs. secondary diagnosis).

## Table: procedures
Medical procedures performed during an encounter, using CPT codes.
Columns: `procedure_id` (PK), `encounter_id` (FK), `cpt_code`,
`description`, `performed_by` (FK to providers), `performed_at`.

## Table: medications
Master medication catalog (not a prescription record). Columns:
`medication_id` (PK), `name`, `generic_name`, `form`
(tablet/syrup/injection), `strength`, `is_controlled_substance` (boolean —
requires extra approval when true).

## Table: prescriptions
Prescriptions issued during an encounter. Columns: `prescription_id`
(PK), `encounter_id` (FK), `medication_id` (FK to medications),
`prescribed_by` (FK to providers), `dosage`, `frequency`,
`duration_days`, `prescribed_at`.

## Table: lab_orders
Laboratory test orders. Columns: `lab_order_id` (PK), `encounter_id`
(FK), `test_type` (e.g. CBC, Lipid Panel, HbA1c), `ordered_by` (FK to
providers), `ordered_at`, `status` (ordered/collected/resulted/cancelled).

## Table: lab_results
Laboratory test results. Columns: `lab_result_id` (PK), `lab_order_id`
(FK), `result_value`, `unit`, `reference_range`, `is_abnormal` (boolean),
`resulted_at`. A single `lab_order` can have many `lab_result` rows (e.g.
a CBC yields several parameters: Hb, WBC, platelet count, etc.).

## Table: vitals
Vital signs recorded during an encounter. Columns: `vital_id` (PK),
`encounter_id` (FK), `recorded_at`, `heart_rate`,
`blood_pressure_systolic`, `blood_pressure_diastolic`,
`temperature_celsius`, `oxygen_saturation`, `recorded_by` (FK to
providers, usually a nurse).

## Table: allergies
Patient allergy history (not per-encounter — attached to the patient for
life unless updated). Columns: `allergy_id` (PK), `patient_id` (FK),
`allergen`, `reaction`, `severity` (mild/moderate/severe), `recorded_at`.

## Table: immunizations
Patient immunization/vaccination history. Columns: `immunization_id`
(PK), `patient_id` (FK), `vaccine_name`, `dose_number`,
`administered_at`, `administered_by` (FK to providers), `lot_number`.

## Table: insurance_policies
Insurance/national health coverage policies held by the patient.
Columns: `policy_id` (PK), `patient_id` (FK), `payer_name` (e.g. a
national health scheme, private insurer), `policy_number`,
`coverage_type`, `valid_from`, `valid_until`.

## Table: claims
Claims submitted to a payer/insurer for an encounter. Columns:
`claim_id` (PK), `encounter_id` (FK), `policy_id` (FK to
insurance_policies), `claim_amount`, `approved_amount`, `status`
(submitted/approved/rejected/partial), `submitted_at`.

## Table: billing_transactions
Actual payment/billing transactions, whether from an insurance claim or
a patient's out-of-pocket payment. Columns: `transaction_id` (PK),
`encounter_id` (FK), `claim_id` (FK, nullable — null for out-of-pocket
payments), `amount`, `payment_method` (insurance/cash/card),
`paid_at`.

---

### Key relationship notes
- `encounters` is the main hub: diagnoses, procedures, prescriptions,
  lab_orders, vitals, claims, and billing_transactions all attach to
  `encounter_id`.
- `patients` is the single source of patient identity — allergies,
  immunizations, and insurance_policies attach directly to `patient_id`
  (not to a specific encounter), since they persist across visits.
- This schema describes structurally sensitive health information (not
  real patient data) — only use synthetic/dummy data for practice, and
  never ingest real patient data into a RAG system without proper
  anonymization and access controls compliant with applicable
  regulations (e.g. HIPAA or your local data protection law).
