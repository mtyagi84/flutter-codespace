-- ============================================================
-- 015_accounts_address_fields.sql
-- Add is_active and division_id to rim_accounts.
-- is_active: IF NOT EXISTS — safe if already in the table.
-- division_id: party address division (State/Province) FK.
-- ============================================================

ALTER TABLE rim_accounts
    ADD COLUMN IF NOT EXISTS is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS division_id UUID    REFERENCES rim_divisions(id);
