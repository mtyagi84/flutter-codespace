-- ============================================================
-- Migration 065: v_grn_return_status — is a GRN fully returned already?
-- ============================================================
-- Found live during UI test: the Purchase Return entry screen's "Approved
-- GRNs" picker showed every APPROVED GRN for the supplier regardless of
-- whether it had already been returned in full — a GRN whose every line
-- was already returned had nothing left to give, but kept showing up as
-- pickable with no indication, confusing the user into re-selecting it.
--
-- Partial returns must stay possible (a GRN can be returned against across
-- several separate documents over time, per the module's own design — see
-- fn_approve_purchase_return's v_already_returned check), so this can't
-- just filter by "has this GRN ever been in a return" — it has to compare
-- the GRN's own total received qty against the SUM of every APPROVED
-- return's qty against it, exactly the same comparison
-- fn_approve_purchase_return itself already does per-line, just rolled up
-- to the whole GRN for the picker's benefit.
-- ============================================================

CREATE OR REPLACE VIEW v_grn_return_status AS
SELECT g.client_id, g.company_id, g.grn_no, g.grn_date,
       g.total_received_qty,
       coalesce(r.total_returned_qty, 0) AS total_returned_qty,
       (coalesce(r.total_returned_qty, 0) >= g.total_received_qty) AS fully_returned
FROM (
    SELECT client_id, company_id, grn_no, grn_date, sum(base_qty) AS total_received_qty
    FROM rid_grn_lines
    WHERE is_deleted = false
    GROUP BY client_id, company_id, grn_no, grn_date
) g
LEFT JOIN (
    SELECT pl.client_id, pl.company_id, pl.source_grn_no AS grn_no, pl.source_grn_date AS grn_date,
           sum(pl.base_qty) AS total_returned_qty
    FROM rid_purchase_return_lines pl
    JOIN rih_purchase_return_headers ph
      ON ph.client_id = pl.client_id AND ph.company_id = pl.company_id
     AND ph.return_no = pl.return_no AND ph.return_date = pl.return_date
    WHERE pl.is_deleted = false AND ph.status = 'APPROVED'
    GROUP BY pl.client_id, pl.company_id, pl.source_grn_no, pl.source_grn_date
) r ON r.client_id = g.client_id AND r.company_id = g.company_id
   AND r.grn_no = g.grn_no AND r.grn_date = g.grn_date;

GRANT SELECT ON v_grn_return_status TO anon, authenticated;
