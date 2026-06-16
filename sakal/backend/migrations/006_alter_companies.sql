-- ============================================================
-- 006_alter_companies.sql
-- Extend ric_companies with full company-profile columns.
-- Run AFTER 001_tenancy.sql (table must exist).
-- ============================================================

-- ── Rename legacy columns ─────────────────────────────────────────────────
ALTER TABLE ric_companies RENAME COLUMN company_short TO company_alias;
ALTER TABLE ric_companies RENAME COLUMN phone         TO landline_no;

-- ── Add new columns ───────────────────────────────────────────────────────
ALTER TABLE ric_companies
    -- Hierarchy
    ADD COLUMN IF NOT EXISTS parent_id          UUID REFERENCES ric_companies(id),

    -- Branding
    ADD COLUMN IF NOT EXISTS tag_line           TEXT,

    -- Extended address
    ADD COLUMN IF NOT EXISTS state_name         TEXT,
    ADD COLUMN IF NOT EXISTS city_name          TEXT,
    ADD COLUMN IF NOT EXISTS pin_zip_code       TEXT,

    -- Additional contact
    ADD COLUMN IF NOT EXISTS website            TEXT,
    ADD COLUMN IF NOT EXISTS mobile_no          TEXT,

    -- Default operational location for this company
    ADD COLUMN IF NOT EXISTS default_store_id   UUID REFERENCES ric_locations(id),

    -- Flexible tax fields — label is region-configurable
    -- Indian:  "GST No." / "PAN No." / "TAN No." / "TIN No."
    -- DRC:     "NIF"     / "RCCM"    / "PATENTE"  / (spare)
    -- Zambia:  "TPIN"    / "VAT No." / (spare)    / (spare)
    ADD COLUMN IF NOT EXISTS tax_1_label        TEXT,
    ADD COLUMN IF NOT EXISTS tax_1_value        TEXT,
    ADD COLUMN IF NOT EXISTS tax_2_label        TEXT,
    ADD COLUMN IF NOT EXISTS tax_2_value        TEXT,
    ADD COLUMN IF NOT EXISTS tax_3_label        TEXT,
    ADD COLUMN IF NOT EXISTS tax_3_value        TEXT,
    ADD COLUMN IF NOT EXISTS tax_4_label        TEXT,
    ADD COLUMN IF NOT EXISTS tax_4_value        TEXT,

    -- Document images stored as base64 TEXT (offline-safe, no file server needed)
    ADD COLUMN IF NOT EXISTS logo               TEXT,
    ADD COLUMN IF NOT EXISTS company_watermark  TEXT,
    ADD COLUMN IF NOT EXISTS company_stamp      TEXT;

-- ── Index ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_ric_companies_parent ON ric_companies(parent_id);
