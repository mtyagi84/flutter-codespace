-- ============================================================
-- Migration 175: Bank Reconciliation — matching engine
-- (junction table, manual match/unmatch, auto-match, reconciliation summary)
-- ============================================================
-- Second of three Bank Reconciliation migrations. Never touches
-- rid_finance_lines or posts any GL entry — matching is a pure
-- cross-reference recording WHICH book line corresponds to WHICH
-- statement line, exactly like rid_invoice_bill_settlement (019) records
-- which payment settled which bill without altering either side.
-- ============================================================

-- ============================================================
-- rid_bank_reconciliation_matches — group-based junction table. Every row
-- created by one match action shares the same match_group_id, so a single
-- action can link N book lines to M statement lines (many-to-many).
-- Unmatch = soft-delete the whole group, never a hard delete (audit trail).
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_bank_reconciliation_matches (
    id                      UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id               UUID          NOT NULL REFERENCES ric_clients(id),
    company_id              UUID          NOT NULL REFERENCES ric_companies(id),
    match_group_id          UUID          NOT NULL,
    bank_account_id         UUID          NOT NULL REFERENCES rim_bank_accounts(id),
    line_type               TEXT          NOT NULL CHECK (line_type IN ('BOOK', 'STATEMENT')),
    -- Exactly one of these two is populated, per line_type.
    finance_line_id         UUID          REFERENCES rid_finance_lines(id),
    bank_statement_line_id  UUID          REFERENCES rid_bank_statement_lines(id),
    matched_amount          NUMERIC(18,4) NOT NULL,
    match_type              TEXT          NOT NULL DEFAULT 'MANUAL' CHECK (match_type IN ('AUTO', 'MANUAL')),
    is_deleted              BOOLEAN       NOT NULL DEFAULT false,
    matched_by              UUID          REFERENCES rim_users(id),
    matched_at              TIMESTAMPTZ   NOT NULL DEFAULT now(),
    unmatched_by            UUID          REFERENCES rim_users(id),
    unmatched_at            TIMESTAMPTZ,
    CONSTRAINT chk_reconciliation_match_line_type CHECK (
        (line_type = 'BOOK'      AND finance_line_id IS NOT NULL AND bank_statement_line_id IS NULL) OR
        (line_type = 'STATEMENT' AND bank_statement_line_id IS NOT NULL AND finance_line_id IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_recon_matches_group   ON rid_bank_reconciliation_matches (match_group_id);
CREATE INDEX IF NOT EXISTS idx_recon_matches_account ON rid_bank_reconciliation_matches (bank_account_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_recon_matches_finance_line ON rid_bank_reconciliation_matches (finance_line_id) WHERE finance_line_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_recon_matches_statement_line ON rid_bank_reconciliation_matches (bank_statement_line_id) WHERE bank_statement_line_id IS NOT NULL;

ALTER TABLE rid_bank_reconciliation_matches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_bank_reconciliation_matches" ON rid_bank_reconciliation_matches;
CREATE POLICY "auth_rw_bank_reconciliation_matches" ON rid_bank_reconciliation_matches
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_bank_reconciliation_matches FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_bank_reconciliation_matches TO authenticated;


-- ============================================================
-- v_bank_reconciliation_book_lines — unreconciled BOOK entries for a bank
-- account. "Unreconciled" is absence-based (no active match row) — same
-- convention as v_pending_bills' own "still outstanding" logic (020).
-- ============================================================
CREATE OR REPLACE VIEW v_bank_reconciliation_book_lines AS
SELECT
    ba.id AS bank_account_id, ba.account_id,
    l.id AS finance_line_id, l.client_id, l.company_id,
    h.trans_no, h.trans_date, h.voucher_type_code, l.serial_no,
    l.trans_nature, l.base_amount, l.line_remarks
FROM rim_bank_accounts ba
JOIN rid_finance_lines l ON l.account_id = ba.account_id
JOIN rih_finance_headers h
    ON  h.client_id = l.client_id AND h.company_id = l.company_id
    AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
WHERE l.is_deleted = false AND h.is_deleted = false AND h.is_posted = true
  AND ba.is_deleted = false
  AND NOT EXISTS (
      SELECT 1 FROM rid_bank_reconciliation_matches m
      WHERE m.finance_line_id = l.id AND m.is_deleted = false
  );

GRANT SELECT ON v_bank_reconciliation_book_lines TO anon, authenticated, service_role;


-- ============================================================
-- v_bank_reconciliation_statement_lines — unreconciled STATEMENT lines,
-- only from APPROVED statements (a DRAFT statement isn't confirmed yet).
-- ============================================================
CREATE OR REPLACE VIEW v_bank_reconciliation_statement_lines AS
SELECT
    h.bank_account_id,
    sl.id AS bank_statement_line_id, sl.client_id, sl.company_id,
    h.statement_no, h.statement_date,
    sl.serial_no, sl.txn_no, sl.txn_date, sl.remarks, sl.debit_amount, sl.credit_amount
FROM rih_bank_statement_headers h
JOIN rid_bank_statement_lines sl
    ON  sl.client_id = h.client_id AND sl.company_id = h.company_id
    AND sl.statement_no = h.statement_no AND sl.statement_date = h.statement_date
WHERE h.is_deleted = false AND sl.is_deleted = false AND h.status = 'APPROVED'
  AND NOT EXISTS (
      SELECT 1 FROM rid_bank_reconciliation_matches m
      WHERE m.bank_statement_line_id = sl.id AND m.is_deleted = false
  );

GRANT SELECT ON v_bank_reconciliation_statement_lines TO anon, authenticated, service_role;


-- ============================================================
-- fn_create_reconciliation_match — manual (or programmatic AUTO) match.
-- Server-validates the two sides' totals agree EXACTLY — never trusts a
-- client-side running-total check alone.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_create_reconciliation_match(
    p_client_id           UUID,
    p_company_id          UUID,
    p_bank_account_id     UUID,
    p_finance_line_ids    UUID[],
    p_statement_line_ids  UUID[],
    p_match_type          TEXT DEFAULT 'MANUAL',
    p_user_id             UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
    v_book_total      NUMERIC;
    v_statement_total NUMERIC;
    v_match_group_id  UUID := gen_random_uuid();
    v_id              UUID;
BEGIN
    IF coalesce(array_length(p_finance_line_ids, 1), 0) = 0
       AND coalesce(array_length(p_statement_line_ids, 1), 0) = 0 THEN
        RAISE EXCEPTION 'Select at least one book entry or statement line to match.';
    END IF;

    SELECT COALESCE(SUM(base_amount), 0) INTO v_book_total
    FROM v_bank_reconciliation_book_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND bank_account_id = p_bank_account_id
      AND finance_line_id = ANY(p_finance_line_ids);

    SELECT COALESCE(SUM(debit_amount + credit_amount), 0) INTO v_statement_total
    FROM v_bank_reconciliation_statement_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND bank_account_id = p_bank_account_id
      AND bank_statement_line_id = ANY(p_statement_line_ids);

    IF abs(v_book_total - v_statement_total) > 0.001 THEN
        RAISE EXCEPTION 'MATCH_AMOUNT_MISMATCH'
            USING DETAIL = format('Selected book entries total %s but selected statement lines total %s — a match must balance exactly.', v_book_total, v_statement_total);
    END IF;

    IF p_finance_line_ids IS NOT NULL THEN
        FOR v_id IN SELECT unnest(p_finance_line_ids) LOOP
            INSERT INTO rid_bank_reconciliation_matches (
                client_id, company_id, match_group_id, bank_account_id, line_type,
                finance_line_id, matched_amount, match_type, matched_by
            )
            SELECT p_client_id, p_company_id, v_match_group_id, p_bank_account_id, 'BOOK',
                   v_id, base_amount, p_match_type, p_user_id
            FROM v_bank_reconciliation_book_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND bank_account_id = p_bank_account_id AND finance_line_id = v_id;
        END LOOP;
    END IF;

    IF p_statement_line_ids IS NOT NULL THEN
        FOR v_id IN SELECT unnest(p_statement_line_ids) LOOP
            INSERT INTO rid_bank_reconciliation_matches (
                client_id, company_id, match_group_id, bank_account_id, line_type,
                bank_statement_line_id, matched_amount, match_type, matched_by
            )
            SELECT p_client_id, p_company_id, v_match_group_id, p_bank_account_id, 'STATEMENT',
                   v_id, debit_amount + credit_amount, p_match_type, p_user_id
            FROM v_bank_reconciliation_statement_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND bank_account_id = p_bank_account_id AND bank_statement_line_id = v_id;
        END LOOP;
    END IF;

    RETURN v_match_group_id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_create_reconciliation_match(
    UUID, UUID, UUID, UUID[], UUID[], TEXT, UUID) TO authenticated;


-- ============================================================
-- fn_remove_reconciliation_match — unmatch, soft-delete the whole group.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_remove_reconciliation_match(
    p_client_id      UUID,
    p_company_id     UUID,
    p_match_group_id UUID,
    p_user_id        UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE rid_bank_reconciliation_matches SET
        is_deleted = true, unmatched_by = p_user_id, unmatched_at = now()
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND match_group_id = p_match_group_id AND is_deleted = false;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Match group % not found or already unmatched', p_match_group_id;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_remove_reconciliation_match(UUID, UUID, UUID, UUID) TO authenticated;


-- ============================================================
-- fn_auto_match_bank_statement — 1:1 exact-amount, close-date pairing
-- ONLY (per the user-confirmed design decision). Any split/bundle match
-- is always a deliberate manual action via fn_create_reconciliation_match.
-- Greedy: each book/statement line is consumed by at most one pair per
-- call, closest-date-first.
-- ============================================================
CREATE OR REPLACE FUNCTION fn_auto_match_bank_statement(
    p_client_id       UUID,
    p_company_id      UUID,
    p_bank_account_id UUID,
    p_date_from       DATE,
    p_date_to         DATE,
    p_date_window_days INTEGER DEFAULT 7,
    p_user_id         UUID DEFAULT NULL
)
RETURNS TABLE (matched_pairs INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_pair RECORD;
    v_count INTEGER := 0;
    v_used_statement_ids UUID[] := ARRAY[]::UUID[];
BEGIN
    FOR v_pair IN
        SELECT b.finance_line_id, b.base_amount, b.trans_date,
               s.bank_statement_line_id, s.txn_date,
               (s.debit_amount + s.credit_amount) AS statement_amount
        FROM v_bank_reconciliation_book_lines b
        JOIN v_bank_reconciliation_statement_lines s
            ON  s.client_id = b.client_id AND s.company_id = b.company_id
            AND s.bank_account_id = b.bank_account_id
            AND abs(b.base_amount - (s.debit_amount + s.credit_amount)) <= 0.001
            AND abs(s.txn_date - b.trans_date) <= p_date_window_days
        WHERE b.client_id = p_client_id AND b.company_id = p_company_id
          AND b.bank_account_id = p_bank_account_id
          AND b.trans_date BETWEEN p_date_from AND p_date_to
        ORDER BY abs(s.txn_date - b.trans_date) ASC
    LOOP
        CONTINUE WHEN v_pair.bank_statement_line_id = ANY(v_used_statement_ids);

        PERFORM fn_create_reconciliation_match(
            p_client_id, p_company_id, p_bank_account_id,
            ARRAY[v_pair.finance_line_id]::UUID[], ARRAY[v_pair.bank_statement_line_id]::UUID[],
            'AUTO', p_user_id
        );

        v_used_statement_ids := array_append(v_used_statement_ids, v_pair.bank_statement_line_id);
        v_count := v_count + 1;
    END LOOP;

    RETURN QUERY SELECT v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_auto_match_bank_statement(
    UUID, UUID, UUID, DATE, DATE, INTEGER, UUID) TO authenticated;


-- ============================================================
-- fn_bank_reconciliation_summary — the classic two-sided schedule.
-- reconciliation_diff flags any residual gap, same "computed diff, never
-- trusted blindly" convention as the Cash Flow Statement's own diff
-- column (migration 145).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_bank_reconciliation_summary(
    p_client_id       UUID,
    p_company_id      UUID,
    p_bank_account_id UUID,
    p_as_of_date      DATE
) RETURNS TABLE (
    book_balance NUMERIC,
    unbooked_bank_credits NUMERIC,
    unbooked_bank_debits NUMERIC,
    adjusted_book_balance NUMERIC,
    bank_statement_balance NUMERIC,
    deposits_in_transit NUMERIC,
    outstanding_cheques NUMERIC,
    adjusted_bank_balance NUMERIC,
    reconciliation_diff NUMERIC
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_account_id UUID;
    v_book_balance NUMERIC;
    v_unbooked_credits NUMERIC;
    v_unbooked_debits NUMERIC;
    v_statement_balance NUMERIC;
    v_deposits_in_transit NUMERIC;
    v_outstanding_cheques NUMERIC;
BEGIN
    SELECT account_id INTO v_account_id FROM rim_bank_accounts WHERE id = p_bank_account_id;

    SELECT balance_base INTO v_book_balance
    FROM fn_cash_bank_position(p_client_id, p_company_id, p_as_of_date, NULL, NULL)
    WHERE account_id = v_account_id;
    v_book_balance := coalesce(v_book_balance, 0);

    SELECT COALESCE(SUM(sl.credit_amount), 0), COALESCE(SUM(sl.debit_amount), 0)
    INTO v_unbooked_credits, v_unbooked_debits
    FROM v_bank_reconciliation_statement_lines sl
    WHERE sl.client_id = p_client_id AND sl.company_id = p_company_id
      AND sl.bank_account_id = p_bank_account_id AND sl.txn_date <= p_as_of_date;

    SELECT h.closing_balance INTO v_statement_balance
    FROM rih_bank_statement_headers h
    WHERE h.client_id = p_client_id AND h.company_id = p_company_id
      AND h.bank_account_id = p_bank_account_id AND h.status = 'APPROVED'
      AND h.period_to <= p_as_of_date AND h.is_deleted = false
    ORDER BY h.period_to DESC LIMIT 1;
    v_statement_balance := coalesce(v_statement_balance, 0);

    SELECT
        COALESCE(SUM(base_amount) FILTER (WHERE trans_nature = 'DR'), 0),
        COALESCE(SUM(base_amount) FILTER (WHERE trans_nature = 'CR'), 0)
    INTO v_deposits_in_transit, v_outstanding_cheques
    FROM v_bank_reconciliation_book_lines bl
    WHERE bl.client_id = p_client_id AND bl.company_id = p_company_id
      AND bl.bank_account_id = p_bank_account_id AND bl.trans_date <= p_as_of_date;

    RETURN QUERY SELECT
        v_book_balance,
        v_unbooked_credits,
        v_unbooked_debits,
        v_book_balance + v_unbooked_credits - v_unbooked_debits,
        v_statement_balance,
        v_deposits_in_transit,
        v_outstanding_cheques,
        v_statement_balance + v_deposits_in_transit - v_outstanding_cheques,
        (v_book_balance + v_unbooked_credits - v_unbooked_debits)
            - (v_statement_balance + v_deposits_in_transit - v_outstanding_cheques);
END;
$$;

GRANT EXECUTE ON FUNCTION fn_bank_reconciliation_summary(UUID, UUID, UUID, DATE) TO authenticated;
