-- add_column_comments.sql
--
-- Batch COMMENT ON COLUMN untuk kolom enum/kategori hasil audit
-- (audit_enum_candidates.sql, run kedua -- sample sudah lengkap).
-- Kolom identifier/free-text (nama, alamat, kode, nomor lot, dll) di-exclude
-- karena low cardinality-nya cuma efek tabel kecil, bukan enum beneran.

-- === Enum jelas, sample terkonfirmasi lengkap ===

COMMENT ON COLUMN patients.gender IS
    'One of: female, male';

COMMENT ON COLUMN allergies.severity IS
    'One of: mild, moderate, severe';

COMMENT ON COLUMN insurance_policies.coverage_type IS
    'One of: Kelas I, Kelas II, Kelas III, Premium, Standard';

COMMENT ON COLUMN medications.form IS
    'One of: capsule, inhaler, injection, syrup, tablet';

COMMENT ON COLUMN lab_orders.status IS
    'Observed value: resulted. Table sample is small (8 rows) -- likely also includes other lab order statuses (e.g. pending, cancelled) not yet observed in this dataset. Verify full domain before relying on this list.';

COMMENT ON COLUMN encounters.encounter_type IS
    'One of: emergency, outpatient';

COMMENT ON COLUMN billing_transactions.payment_method IS
    'One of: bank_transfer, card, cash, insurance';

-- === Prioritas menengah: kategori tetap (fixed set) tapi lebih ke daftar referensi daripada status ===

COMMENT ON COLUMN insurance_policies.payer_name IS
    'Insurer name. Observed values: Allianz, AXA Mandiri, BPJS Kesehatan, Prudential';

COMMENT ON COLUMN departments.name IS
    'Department name. Observed values: Cardiology, Emergency, Internal Medicine, Pediatrics, Radiology';

COMMENT ON COLUMN providers.specialty IS
    'Medical specialty. Observed values: Cardiology, Emergency Medicine, Internal Medicine, Pediatrics, Radiology';