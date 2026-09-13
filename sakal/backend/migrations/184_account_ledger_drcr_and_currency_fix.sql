-- ============================================================
-- Migration 184: Account Ledger -- Dr/Cr display + missing currency on totals
-- ============================================================
-- 2 real bugs found live 2026-09-13:
--   1. running_balance is a genuinely SIGNED numeric value (positive = net
--      Dr, negative = net Cr) rendered through the generic 'NUMBER' column
--      type -- it displays as a bare negative number for a credit balance
--      instead of a Dr/Cr-labeled amount. Trial Balance (135) already
--      solved this exact problem correctly: it returns an ABS() magnitude
--      in one column plus a companion `..._type` TEXT column ('Dr'/'Cr')
--      rendered right next to it (`opening_balance`+`opening_balance_type`,
--      `closing_balance`+`closing_balance_type`). This migration applies
--      the identical, already-proven pattern to Account Ledger's
--      running_balance instead of inventing a new mechanism.
--   2. fn_account_ledger_totals (the footer/summary row -- the single most
--      prominent number on the report) never returned `currency_code` at
--      all, in ANY currency mode -- confirmed by reading its RETURNS TABLE
--      (debit, credit, running_balance only). The per-row currency_code
--      column on fn_account_ledger_lines was already correct; the totals
--      footer was the gap. Fixed by adding it there too.
--
-- Both RETURNS TABLE shapes are only ever APPENDED to at the end (never a
-- column inserted mid-list) -- Postgres cannot change an existing
-- function's OUT-parameter-based return shape that way (see this
-- project's own migration-idempotency rule).
-- ============================================================

DROP FUNCTION IF EXISTS fn_account_ledger_lines(UUID, UUID, UUID, DATE, DATE, TEXT, TEXT);
CREATE FUNCTION fn_account_ledger_lines(
    p_client_id      UUID,
    p_company_id     UUID,
    p_account_id     UUID DEFAULT NULL,
    p_date_from      DATE DEFAULT NULL,
    p_date_to        DATE DEFAULT NULL,
    p_currency_mode  TEXT DEFAULT 'PARTY',
    p_posting_filter TEXT DEFAULT 'POSTED'
) RETURNS TABLE (
    trans_no             TEXT,
    trans_date           DATE,
    remarks              TEXT,
    debit                NUMERIC,
    credit               NUMERIC,
    running_balance      NUMERIC,
    currency_code        TEXT,
    sort_seq             BIGINT,
    running_balance_type TEXT
) LANGUAGE sql STABLE AS $$
    WITH qualifying_lines AS (
        SELECT
            h.trans_no, h.trans_date, l.serial_no, l.trans_nature,
            CASE p_currency_mode
                WHEN 'BASE'  THEN l.base_amount
                WHEN 'LOCAL' THEN l.local_amount
                ELSE              l.party_amount
            END AS amt,
            COALESCE(l.line_remarks, h.remarks, '')
                || CASE WHEN l.inv_bill_no IS NOT NULL
                        THEN ' | Bill: ' || l.inv_bill_no
                             || COALESCE(' dated ' || to_char(l.inv_bill_date, 'DD Mon YYYY'), '')
                        ELSE '' END
                || CASE WHEN h.reference_no IS NOT NULL
                        THEN ' | Ref: ' || h.reference_no
                             || COALESCE(' dated ' || to_char(h.reference_date, 'DD Mon YYYY'), '')
                        ELSE '' END AS remarks
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.account_id = p_account_id
          AND l.is_deleted = false AND h.is_deleted = false
          AND (p_posting_filter <> 'POSTED' OR h.is_posted = true)
          AND (
              NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                          WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                            AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                            AND ula.is_active = true AND ula.is_deleted = false)
              OR h.location_id IN (SELECT ula.location_id
                                   FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = h.client_id
                                      AND ula.company_id = h.company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
    ),
    opening AS (
        SELECT COALESCE(SUM(CASE WHEN trans_nature = 'DR' THEN amt ELSE -amt END), 0) AS bal
        FROM qualifying_lines
        WHERE p_date_from IS NOT NULL AND trans_date < p_date_from
    ),
    combined AS (
        SELECT
            0 AS sort_priority,
            'Opening Balance'::TEXT AS trans_no,
            COALESCE(p_date_from, DATE '1900-01-01') AS trans_date,
            0 AS serial_no,
            ''::TEXT AS remarks,
            NULL::NUMERIC AS debit,
            NULL::NUMERIC AS credit,
            (SELECT bal FROM opening) AS signed_amt
        UNION ALL
        SELECT
            1 AS sort_priority,
            trans_no, trans_date, serial_no, remarks,
            CASE WHEN trans_nature = 'DR' THEN amt END AS debit,
            CASE WHEN trans_nature = 'CR' THEN amt END AS credit,
            CASE WHEN trans_nature = 'DR' THEN amt ELSE -amt END AS signed_amt
        FROM qualifying_lines
        WHERE (p_date_from IS NULL OR trans_date >= p_date_from)
          AND (p_date_to   IS NULL OR trans_date <= p_date_to)
    ),
    with_running AS (
        SELECT
            c.trans_no, c.trans_date, c.remarks, c.debit, c.credit,
            SUM(c.signed_amt) OVER (
                ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.serial_no
                ROWS UNBOUNDED PRECEDING
            ) AS signed_running_balance,
            ROW_NUMBER() OVER (ORDER BY c.sort_priority, c.trans_date, c.trans_no, c.serial_no) AS sort_seq
        FROM combined c
    )
    SELECT
        w.trans_no, w.trans_date, w.remarks, w.debit, w.credit,
        ABS(w.signed_running_balance) AS running_balance,
        (CASE p_currency_mode
            WHEN 'BASE'  THEN (SELECT base_currency  FROM ric_companies WHERE id = p_company_id)
            WHEN 'LOCAL' THEN (SELECT local_currency FROM ric_companies WHERE id = p_company_id)
            ELSE (SELECT rc.currency_id FROM rim_accounts a
                  JOIN rim_currencies rc ON rc.id = a.account_currency_id
                  WHERE a.id = p_account_id)
        END) AS currency_code,
        w.sort_seq,
        CASE WHEN w.signed_running_balance < 0 THEN 'Cr' ELSE 'Dr' END AS running_balance_type
    FROM with_running w
    ORDER BY w.sort_seq;
$$;

GRANT EXECUTE ON FUNCTION fn_account_ledger_lines(
    UUID, UUID, UUID, DATE, DATE, TEXT, TEXT) TO authenticated;


DROP FUNCTION IF EXISTS fn_account_ledger_totals(UUID, UUID, UUID, DATE, DATE, TEXT, TEXT);
CREATE FUNCTION fn_account_ledger_totals(
    p_client_id      UUID,
    p_company_id     UUID,
    p_account_id     UUID DEFAULT NULL,
    p_date_from      DATE DEFAULT NULL,
    p_date_to        DATE DEFAULT NULL,
    p_currency_mode  TEXT DEFAULT 'PARTY',
    p_posting_filter TEXT DEFAULT 'POSTED'
) RETURNS TABLE (
    debit                NUMERIC,
    credit               NUMERIC,
    running_balance      NUMERIC,
    currency_code        TEXT,
    running_balance_type TEXT
) LANGUAGE sql STABLE AS $$
    WITH scoped AS (
        SELECT
            h.trans_date, l.trans_nature,
            CASE p_currency_mode
                WHEN 'BASE'  THEN l.base_amount
                WHEN 'LOCAL' THEN l.local_amount
                ELSE              l.party_amount
            END AS amt
        FROM rid_finance_lines l
        JOIN rih_finance_headers h
            ON h.client_id = l.client_id AND h.company_id = l.company_id
           AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
        WHERE l.client_id = p_client_id AND l.company_id = p_company_id
          AND l.account_id = p_account_id
          AND l.is_deleted = false AND h.is_deleted = false
          AND (p_posting_filter <> 'POSTED' OR h.is_posted = true)
          AND (p_date_to IS NULL OR h.trans_date <= p_date_to)
          AND (
              NOT EXISTS (SELECT 1 FROM ric_user_location_access ula
                          WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                            AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                            AND ula.is_active = true AND ula.is_deleted = false)
              OR h.location_id IN (SELECT ula.location_id FROM ric_user_location_access ula
                                    WHERE ula.user_id = (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid
                                      AND ula.client_id = h.client_id AND ula.company_id = h.company_id
                                      AND ula.is_active = true AND ula.is_deleted = false)
          )
    ),
    agg AS (
        SELECT
            COALESCE(SUM(amt) FILTER (
                WHERE trans_nature = 'DR' AND (p_date_from IS NULL OR trans_date >= p_date_from)), 0) AS debit,
            COALESCE(SUM(amt) FILTER (
                WHERE trans_nature = 'CR' AND (p_date_from IS NULL OR trans_date >= p_date_from)), 0) AS credit,
            COALESCE(SUM(CASE WHEN trans_nature = 'DR' THEN amt ELSE -amt END), 0) AS signed_running_balance
        FROM scoped
    )
    SELECT
        a.debit, a.credit,
        ABS(a.signed_running_balance) AS running_balance,
        (CASE p_currency_mode
            WHEN 'BASE'  THEN (SELECT base_currency  FROM ric_companies WHERE id = p_company_id)
            WHEN 'LOCAL' THEN (SELECT local_currency FROM ric_companies WHERE id = p_company_id)
            ELSE (SELECT rc.currency_id FROM rim_accounts acct
                  JOIN rim_currencies rc ON rc.id = acct.account_currency_id
                  WHERE acct.id = p_account_id)
        END) AS currency_code,
        CASE WHEN a.signed_running_balance < 0 THEN 'Cr' ELSE 'Dr' END AS running_balance_type
    FROM agg a;
$$;

GRANT EXECUTE ON FUNCTION fn_account_ledger_totals(
    UUID, UUID, UUID, DATE, DATE, TEXT, TEXT) TO authenticated;


-- ============================================================
-- Column registry: add running_balance_type next to running_balance
-- (same TEXT/CENTER shape as Trial Balance's own opening_balance_type/
-- closing_balance_type), for every existing company. currency_code
-- already exists as a registered column (migration 132) -- no change
-- needed there, it was already correctly configured, just never
-- returned by the totals function until now.
-- ============================================================
INSERT INTO ric_report_columns
    (client_id, company_id, report_id, column_key, label, data_type, align, sortable, default_visible,
     default_width, sort_order, aggregate_fn)
SELECT
    rd.client_id, rd.company_id, rd.id, 'running_balance_type', 'Bal. Type', 'TEXT', 'CENTER', false, true, 70, 7, NULL
FROM ric_report_definitions rd
WHERE rd.report_key = 'ACCOUNT_LEDGER'
ON CONFLICT (report_id, column_key) DO NOTHING;

-- Shift currency_code and sort_seq's sort_order down by one to make room
-- (running_balance_type now sits at 7, currency_code at 8, sort_seq at 9)
-- -- purely a display-order cosmetic, not a schema change.
UPDATE ric_report_columns rc
SET sort_order = 8
FROM ric_report_definitions rd
WHERE rc.report_id = rd.id AND rd.report_key = 'ACCOUNT_LEDGER' AND rc.column_key = 'currency_code';

UPDATE ric_report_columns rc
SET sort_order = 9
FROM ric_report_definitions rd
WHERE rc.report_id = rd.id AND rd.report_key = 'ACCOUNT_LEDGER' AND rc.column_key = 'sort_seq';
