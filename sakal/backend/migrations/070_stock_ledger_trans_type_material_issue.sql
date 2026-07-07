-- ============================================================
-- Migration 070: ril_stock_ledger.trans_type CHECK — add MATERIAL_ISSUE
-- ============================================================
-- 069 fixed chk_stock_ledger_direction but missed that ril_stock_ledger
-- ALSO has a SEPARATE, separately-named column-level CHECK constraint on
-- trans_type itself (036's inline CHECK on the column declaration,
-- auto-named ril_stock_ledger_trans_type_check by Postgres) — a plain
-- enum whitelist of every valid trans_type regardless of direction. It
-- has the exact same gap: MATERIAL_ISSUE was never added.
--
-- Two independent constraints enforcing overlapping-but-different things
-- on the same column is exactly why this was missed once already — both
-- must be checked (and updated together) whenever a new trans_type is
-- introduced for any future fn_post_stock_movement caller.
-- ============================================================

ALTER TABLE ril_stock_ledger DROP CONSTRAINT ril_stock_ledger_trans_type_check;

ALTER TABLE ril_stock_ledger ADD CONSTRAINT ril_stock_ledger_trans_type_check
    CHECK (trans_type IN (
        'GRN','GRN_REVERSAL','PURCHASE_RETURN',
        'SALES_INVOICE','SALES_RETURN',
        'TRANSFER_OUT','TRANSFER_IN',
        'ADJUSTMENT_IN','ADJUSTMENT_OUT','OPENING_STOCK',
        'MATERIAL_ISSUE'
    ));
