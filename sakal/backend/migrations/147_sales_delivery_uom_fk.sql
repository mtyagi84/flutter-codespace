-- ============================================================
-- Migration 147: rid_sales_delivery_lines.uom_id — missing foreign key
-- ============================================================
-- Real bug caught live: migration 102 defined `uom_id UUID` on
-- rid_sales_delivery_lines with no REFERENCES clause at all — unlike
-- every sibling line table (rid_sales_invoice_lines.uom_id, migration
-- 089: `UUID NOT NULL REFERENCES rim_common_masters(id)`). PostgREST's
-- embed syntax (`uom:rim_common_masters!uom_id(description)`, used by
-- both fn_getLines and fn_getInvoiceLines in
-- sales_delivery_remote_ds.dart) requires a REAL foreign key to resolve
-- the relationship — without one, PostgREST raises "Could not find a
-- relationship between 'rid_sales_delivery_lines' and
-- 'rim_common_masters' using the hint 'uom_id'" on every attempt to view
-- a delivery's own lines (both the invoice-lines-to-deliver picker and
-- an already-approved delivery's own saved lines).
--
-- Defensive NULL-out before adding the constraint, in case any row's
-- uom_id (written before this fix existed) doesn't actually match a
-- live rim_common_masters row — never destructive to a real value, just
-- a safety net so this migration can't fail on unexpected data.
-- ============================================================

UPDATE rid_sales_delivery_lines l
SET uom_id = NULL
WHERE l.uom_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM rim_common_masters m WHERE m.id = l.uom_id);

-- Plain ALTER TABLE ADD CONSTRAINT has no IF NOT EXISTS in Postgres —
-- guarded so re-running this migration mid-session doesn't fail with
-- "constraint already exists" (same idempotency rule as this project's
-- own CREATE TRIGGER/CREATE POLICY convention).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'rid_sd_lines_uom_fk'
    ) THEN
        ALTER TABLE rid_sales_delivery_lines
            ADD CONSTRAINT rid_sd_lines_uom_fk FOREIGN KEY (uom_id) REFERENCES rim_common_masters(id);
    END IF;
END $$;
