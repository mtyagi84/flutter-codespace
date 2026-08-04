-- ============================================================
-- Migration 117: v_pending_bills — add base/local amounts + account label
-- ============================================================
-- Follow-up to migration 020 (already run — never edit it directly, see
-- CLAUDE.md's "Migration Already Run" rule). v_pending_bills only ever
-- exposed party_amount (bill_amount)/party_currency/account_id, which was
-- fine for its original consumer (Finance Voucher entry screen's
-- Against-Bill picker, always scoped to one account/customer at a time,
-- looking the account up separately). Using this same view as the
-- Reporting Engine's two Tabular pilots (migration 118) changes that:
-- - A report can legitimately list pending bills across many
--   customers/currencies at once, and party_amount/party_currency VARY
--   per row — summing them would violate the reporting engine's own
--   multi-currency rule (only base_amount/local_amount are safe to
--   aggregate, see sakal/docs/reporting_engine_design.md).
-- - The grouped pilot groups by customer and wants a human-readable label
--   (account_code/account_name), not a raw account_id.
-- Appending these columns at the end of the SELECT list is safe under
-- CREATE OR REPLACE VIEW (Postgres allows appending, never
-- removing/reordering existing output columns) — no existing consumer of
-- this view is affected.

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
    l.party_amount - COALESCE(s.settled_amt, 0)       AS balance_amount,
    l.base_amount                                     AS bill_amount_base,
    l.local_amount                                    AS bill_amount_local,
    a.account_code,
    a.account_name
FROM rid_finance_lines l
JOIN rih_finance_headers h
    ON  h.client_id   = l.client_id
    AND h.company_id  = l.company_id
    AND h.location_id = l.location_id
    AND h.trans_no    = l.trans_no
JOIN rim_accounts a
    ON  a.id = l.account_id
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

-- PostgREST access (unchanged from migration 020 — re-stated for clarity,
-- GRANT is idempotent)
GRANT SELECT ON v_pending_bills TO anon, authenticated, service_role;
