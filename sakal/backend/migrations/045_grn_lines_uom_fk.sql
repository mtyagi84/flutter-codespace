-- ============================================================
-- Migration 045: add missing FK on rid_grn_lines.uom_id
-- ============================================================
-- Gap found while wiring the GRN Flutter screens: migration 038 declared
-- rid_grn_lines.uom_id as a bare UUID with no REFERENCES clause, unlike its
-- Purchase Order counterpart (rid_purchase_order_lines.uom_id UUID NOT NULL
-- REFERENCES rim_common_masters(id)). Without the FK, PostgREST cannot
-- resolve the embedded select GrnRemoteDs.getLines() relies on
-- ('uom:rim_common_masters!uom_id(description)') — it would 404 with
-- "Could not find a relationship between rid_grn_lines and
-- rim_common_masters in the schema cache".
--
-- A new follow-up migration, not an edit to 038 — 038 may already be
-- deployed, and editing an already-run migration file has no effect on a
-- live schema (see CLAUDE.md's "Migration Already Run" note).
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_grn_lines_uom_id'
    ) THEN
        ALTER TABLE rid_grn_lines
            ADD CONSTRAINT fk_grn_lines_uom_id FOREIGN KEY (uom_id) REFERENCES rim_common_masters(id);
    END IF;
END $$;
