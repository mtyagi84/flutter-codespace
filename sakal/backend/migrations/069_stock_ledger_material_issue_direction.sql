-- ============================================================
-- Migration 069: ril_stock_ledger direction check — add MATERIAL_ISSUE
-- ============================================================
-- chk_stock_ledger_direction (036) whitelists which trans_type values are
-- allowed for inward (qty_change > 0) vs outward (qty_change < 0)
-- movements. It anticipated PURCHASE_RETURN/TRANSFER_OUT/ADJUSTMENT_OUT as
-- future outward types but not MATERIAL_ISSUE (068, built later) — every
-- fn_approve_material_issue call failed the constraint outright.
-- ============================================================

ALTER TABLE ril_stock_ledger DROP CONSTRAINT chk_stock_ledger_direction;

ALTER TABLE ril_stock_ledger ADD CONSTRAINT chk_stock_ledger_direction CHECK (
    (trans_type IN ('GRN', 'TRANSFER_IN', 'ADJUSTMENT_IN', 'OPENING_STOCK', 'SALES_RETURN') AND qty_change > 0)
    OR
    (trans_type IN ('GRN_REVERSAL', 'PURCHASE_RETURN', 'SALES_INVOICE', 'TRANSFER_OUT', 'ADJUSTMENT_OUT', 'MATERIAL_ISSUE') AND qty_change < 0)
);
