-- 020_pending_bills_view.sql
-- VIEW: v_pending_bills
-- Purpose: Shows original invoice/bill lines (inv_bill_no IS NOT NULL) with the
--          remaining balance after deducting payments already settled via
--          rid_invoice_bill_settlement (only POSTED vouchers affect settlement).
-- Used by: Finance Voucher Entry screen, Against Bill mode.

CREATE OR REPLACE VIEW v_pending_bills AS
SELECT
    l.client_id,
    l.company_id,
    l.location_id,
    l.account_id,
    h.trans_no,
    h.trans_date,
    l.inv_bill_no,
    l.inv_bill_date,
    l.party_amount                                    AS bill_amount,
    l.party_currency,
    COALESCE(s.settled_amt, 0)                        AS settled_amount,
    l.party_amount - COALESCE(s.settled_amt, 0)       AS balance_amount
FROM rid_finance_lines l
JOIN rih_finance_headers h
    ON  h.client_id   = l.client_id
    AND h.company_id  = l.company_id
    AND h.location_id = l.location_id
    AND h.trans_no    = l.trans_no
LEFT JOIN (
    SELECT
        client_id,
        company_id,
        location_id,
        account_id,
        inv_bill_no,
        SUM(paid_amount) AS settled_amt
    FROM   rid_invoice_bill_settlement
    WHERE  is_deleted = FALSE
    GROUP  BY client_id, company_id, location_id, account_id, inv_bill_no
) s ON  s.client_id   = l.client_id
    AND s.company_id  = l.company_id
    AND s.location_id = l.location_id
    AND s.account_id  = l.account_id
    AND s.inv_bill_no = l.inv_bill_no
WHERE l.inv_bill_no   IS NOT NULL
  AND l.is_deleted    = FALSE
  AND h.is_deleted    = FALSE
  AND h.is_posted     = TRUE
  AND l.party_amount - COALESCE(s.settled_amt, 0) > 0.001;

-- PostgREST access
GRANT SELECT ON v_pending_bills TO anon, authenticated, service_role;
