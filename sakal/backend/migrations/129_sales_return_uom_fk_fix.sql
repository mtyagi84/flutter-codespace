-- ============================================================
-- Migration 129: rid_sales_return_lines.uom_id was missing its foreign
-- key to rim_common_masters(id) — every sibling line table (e.g.
-- rid_sales_invoice_lines) declares this FK, but 099_sales_return.sql
-- declared uom_id as a bare UUID column with no REFERENCES clause.
-- PostgREST's embed resolution (`uom:rim_common_masters!uom_id(...)`,
-- used identically by sales_return_remote_ds.dart and every other
-- module's datasource) requires a real FK constraint to resolve a
-- relationship hint — without one, every Sales Return line query failed
-- with "no matches were found" for the uom_id hint. The Flutter code was
-- already correct; this is purely a missing constraint.
-- ============================================================
ALTER TABLE rid_sales_return_lines DROP CONSTRAINT IF EXISTS rid_sales_return_lines_uom_id_fkey;
ALTER TABLE rid_sales_return_lines
    ADD CONSTRAINT rid_sales_return_lines_uom_id_fkey
    FOREIGN KEY (uom_id) REFERENCES rim_common_masters(id);
