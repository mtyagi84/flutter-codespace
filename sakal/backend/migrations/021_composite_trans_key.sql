-- ============================================================
-- 021_composite_trans_key.sql
--
-- Problem: rih_finance_headers unique constraint was only (trans_no),
-- but trans_no can reset monthly/yearly, so the same number can legitimately
-- reappear in a later period. The correct identity for a transaction is
-- (trans_no, trans_date) — they must always travel together.
--
-- Changes:
--   1. rih_finance_headers — widen unique key to (trans_no, trans_date)
--   2. rid_finance_lines   — add trans_date column, update FK + unique key
--   3. rid_cheque_register — add trans_date column, update FK
--   4. v_pending_bills     — join on both trans_no AND trans_date
--   5. fn_save_finance_voucher — split UPSERT → conditional INSERT/UPDATE,
--                                store trans_date in every line row
--   6. fn_post_finance_voucher — add p_trans_date param,
--                                use composite key in all WHERE clauses
-- ============================================================

BEGIN;

-- ── 1. rih_finance_headers ────────────────────────────────────────────────────

ALTER TABLE rih_finance_headers
    DROP CONSTRAINT uq_rih_finance_headers;

ALTER TABLE rih_finance_headers
    ADD CONSTRAINT uq_rih_finance_headers
        UNIQUE (client_id, company_id, location_id, trans_no, trans_date);


-- ── 2. rid_finance_lines ──────────────────────────────────────────────────────

ALTER TABLE rid_finance_lines
    ADD COLUMN trans_date date;

-- Back-fill from the header (safe: old constraint guaranteed trans_no was unique per tenant)
UPDATE rid_finance_lines l
SET    trans_date = h.trans_date
FROM   rih_finance_headers h
WHERE  h.client_id   = l.client_id
  AND  h.company_id  = l.company_id
  AND  h.location_id = l.location_id
  AND  h.trans_no    = l.trans_no;

ALTER TABLE rid_finance_lines
    ALTER COLUMN trans_date SET NOT NULL;

ALTER TABLE rid_finance_lines
    DROP CONSTRAINT rid_finance_lines_header_fk,
    DROP CONSTRAINT uq_rid_finance_lines;

ALTER TABLE rid_finance_lines
    ADD CONSTRAINT rid_finance_lines_header_fk
        FOREIGN KEY (client_id, company_id, location_id, trans_no, trans_date)
        REFERENCES  rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date),
    ADD CONSTRAINT uq_rid_finance_lines
        UNIQUE (client_id, company_id, location_id, trans_no, trans_date, serial_no);


-- ── 3. rid_cheque_register ────────────────────────────────────────────────────

ALTER TABLE rid_cheque_register
    ADD COLUMN trans_date date;

UPDATE rid_cheque_register r
SET    trans_date = h.trans_date
FROM   rih_finance_headers h
WHERE  h.client_id   = r.client_id
  AND  h.company_id  = r.company_id
  AND  h.location_id = r.location_id
  AND  h.trans_no    = r.trans_no;

ALTER TABLE rid_cheque_register
    ALTER COLUMN trans_date SET NOT NULL;

ALTER TABLE rid_cheque_register
    DROP CONSTRAINT rid_cheque_register_header_fk;

ALTER TABLE rid_cheque_register
    ADD CONSTRAINT rid_cheque_register_header_fk
        FOREIGN KEY (client_id, company_id, location_id, trans_no, trans_date)
        REFERENCES  rih_finance_headers (client_id, company_id, location_id, trans_no, trans_date);


-- ── 4. v_pending_bills ────────────────────────────────────────────────────────
-- Re-create with trans_date added to the header JOIN condition.

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
    AND h.trans_date  = l.trans_date          -- composite key join
LEFT JOIN (
    SELECT
        client_id, company_id, location_id,
        account_id, inv_bill_no,
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

GRANT SELECT ON v_pending_bills TO anon, authenticated, service_role;


-- ── 5. fn_save_finance_voucher ────────────────────────────────────────────────
-- The old UPSERT (ON CONFLICT on trans_no) cannot handle date changes safely
-- once trans_date is part of the unique key.
-- New pattern:
--   NEW voucher  → INSERT header, then INSERT lines
--   EDIT draft   → DELETE lines first (avoids FK hold), UPDATE header, INSERT lines
-- trans_date is now explicitly stored in every rid_finance_lines row.

CREATE OR REPLACE FUNCTION fn_save_finance_voucher(
    p_header    jsonb,
    p_lines     jsonb,
    p_user_id   uuid
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     uuid;
    v_company_id    uuid;
    v_location_id   uuid;
    v_trans_no      text;
    v_trans_date    date;
    v_is_new        boolean;
    v_line          jsonb;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_trans_no    := nullif(trim(p_header->>'trans_no'), '');
    v_trans_date  := (p_header->>'trans_date')::date;
    v_is_new      := v_trans_no IS NULL;

    IF v_is_new THEN
        v_trans_no := fn_next_trans_no(
            v_client_id, v_company_id, v_location_id,
            p_header->>'voucher_type_code'
        );
    ELSE
        IF EXISTS (
            SELECT 1 FROM rih_finance_headers
            WHERE client_id   = v_client_id
              AND company_id  = v_company_id
              AND location_id = v_location_id
              AND trans_no    = v_trans_no
              AND is_posted   = true
        ) THEN
            RAISE EXCEPTION
                'Voucher % is already posted and cannot be modified. Use Reversal to correct.',
                v_trans_no;
        END IF;
    END IF;

    -- Delete existing draft lines first so header trans_date can change freely
    -- (lines hold the FK; deleting them removes the constraint hold before UPDATE)
    DELETE FROM rid_finance_lines
    WHERE client_id   = v_client_id
      AND company_id  = v_company_id
      AND location_id = v_location_id
      AND trans_no    = v_trans_no;

    -- Insert or update header
    IF v_is_new THEN
        INSERT INTO rih_finance_headers (
            client_id, company_id, location_id, trans_no, trans_date,
            voucher_type_code, payment_mode_code, is_on_account,
            reference_no, reference_date,
            cheque_no, cheque_date,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id,
            v_trans_no, v_trans_date,
            p_header->>'voucher_type_code',
            nullif(p_header->>'payment_mode_code', ''),
            coalesce((p_header->>'is_on_account')::boolean, false),
            nullif(p_header->>'reference_no', ''),
            (nullif(p_header->>'reference_date', ''))::date,
            nullif(p_header->>'cheque_no', ''),
            (nullif(p_header->>'cheque_date', ''))::date,
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        -- Update existing unposted draft; trans_date may legitimately change
        UPDATE rih_finance_headers SET
            trans_date        = v_trans_date,
            payment_mode_code = nullif(p_header->>'payment_mode_code', ''),
            is_on_account     = coalesce((p_header->>'is_on_account')::boolean, false),
            reference_no      = nullif(p_header->>'reference_no', ''),
            reference_date    = (nullif(p_header->>'reference_date', ''))::date,
            cheque_no         = nullif(p_header->>'cheque_no', ''),
            cheque_date       = (nullif(p_header->>'cheque_date', ''))::date,
            remarks           = nullif(p_header->>'remarks', ''),
            updated_at        = now(),
            updated_by        = p_user_id
        WHERE client_id   = v_client_id
          AND company_id  = v_company_id
          AND location_id = v_location_id
          AND trans_no    = v_trans_no
          AND is_posted   = false
          AND is_deleted  = false;
    END IF;

    -- Re-insert lines with trans_date carried from the header
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_finance_lines (
            client_id, company_id, location_id, trans_no, trans_date,
            serial_no, account_id, trans_nature,
            trans_amount, trans_currency,
            base_amount,  base_rate,
            local_amount, local_rate,
            party_amount, party_currency, party_rate,
            inv_bill_no, inv_bill_date,
            line_remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_trans_no, v_trans_date,
            (v_line->>'serial_no')::integer,
            (v_line->>'account_id')::uuid,
            v_line->>'trans_nature',
            coalesce((v_line->>'trans_amount')::numeric,  0),
            v_line->>'trans_currency',
            coalesce((v_line->>'base_amount')::numeric,   0),
            coalesce((v_line->>'base_rate')::numeric,     1),
            coalesce((v_line->>'local_amount')::numeric,  0),
            coalesce((v_line->>'local_rate')::numeric,    1),
            coalesce((v_line->>'party_amount')::numeric,  0),
            v_line->>'party_currency',
            coalesce((v_line->>'party_rate')::numeric,    1),
            nullif(v_line->>'inv_bill_no', ''),
            (nullif(v_line->>'inv_bill_date', ''))::date,
            nullif(v_line->>'line_remarks', ''),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_trans_no;
END;
$$;


-- ── 6. fn_post_finance_voucher ────────────────────────────────────────────────
-- Added p_trans_date parameter so the caller identifies the voucher unambiguously.
-- All WHERE clauses that previously used only trans_no now use (trans_no, trans_date).
-- The settlement origin lookup also uses (inv_bill_no, inv_bill_date) as composite
-- key into rid_finance_lines to find the correct original invoice line.

CREATE OR REPLACE FUNCTION fn_post_finance_voucher(
    p_client_id   uuid,
    p_company_id  uuid,
    p_location_id uuid,
    p_trans_no    text,
    p_trans_date  date,
    p_posted_by   uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_header        rih_finance_headers%rowtype;
    v_line          rid_finance_lines%rowtype;
    v_imbalance     numeric;
    v_was_balance   numeric;
    v_settle_no     integer;
BEGIN
    -- Lock and load using composite key
    SELECT * INTO v_header FROM rih_finance_headers
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = p_trans_no
      AND trans_date  = p_trans_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher % dated % not found', p_trans_no, p_trans_date;
    END IF;

    IF v_header.is_posted THEN
        RAISE EXCEPTION 'Voucher % is already posted', p_trans_no;
    END IF;

    -- Validate DR = CR (allow 0.01 rounding tolerance)
    SELECT abs(sum(
        CASE WHEN trans_nature = 'DR' THEN trans_amount ELSE -trans_amount END
    ))
    INTO v_imbalance
    FROM rid_finance_lines
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = p_trans_no
      AND trans_date  = p_trans_date
      AND is_deleted  = false;

    IF coalesce(v_imbalance, 0) > 0.01 THEN
        RAISE EXCEPTION
            'Voucher % is not balanced — DR and CR totals do not match (difference: %)',
            p_trans_no, v_imbalance;
    END IF;

    -- Mark as posted
    UPDATE rih_finance_headers SET
        is_posted  = true,
        posted_at  = now(),
        posted_by  = p_posted_by,
        updated_at = now(),
        updated_by = p_posted_by
    WHERE client_id   = p_client_id
      AND company_id  = p_company_id
      AND location_id = p_location_id
      AND trans_no    = p_trans_no
      AND trans_date  = p_trans_date;

    -- Cheque register entry
    IF v_header.cheque_no IS NOT NULL THEN
        INSERT INTO rid_cheque_register (
            client_id, company_id, location_id,
            trans_no, trans_date,
            cheque_no, cheque_date,
            cheque_status, created_by, updated_by
        ) VALUES (
            p_client_id, p_company_id, p_location_id,
            p_trans_no, p_trans_date,
            v_header.cheque_no, v_header.cheque_date,
            'ISSUED', p_posted_by, p_posted_by
        )
        ON CONFLICT DO NOTHING;
    END IF;

    -- Settlement records: Against Bill vouchers only
    IF NOT v_header.is_on_account THEN
        FOR v_line IN
            SELECT * FROM rid_finance_lines
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND trans_no    = p_trans_no
              AND trans_date  = p_trans_date
              AND is_deleted  = false
              AND inv_bill_no IS NOT NULL
        LOOP
            -- Original invoice line: inv_bill_no = invoice trans_no,
            --                        inv_bill_date = invoice trans_date (composite key)
            SELECT coalesce(party_amount - settled_amount, 0)
            INTO v_was_balance
            FROM rid_finance_lines
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND trans_no    = v_line.inv_bill_no
              AND trans_date  = v_line.inv_bill_date
              AND account_id  = v_line.account_id
              AND is_deleted  = false
            LIMIT 1;

            SELECT coalesce(max(settlement_no), 0) + 1
            INTO v_settle_no
            FROM rid_invoice_bill_settlement
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND account_id  = v_line.account_id
              AND inv_bill_no = v_line.inv_bill_no
              AND is_deleted  = false;

            INSERT INTO rid_invoice_bill_settlement (
                client_id, company_id, location_id,
                trans_no, trans_date, voucher_type_code,
                account_id, inv_bill_no, inv_bill_date,
                settlement_no, was_balance, paid_amount, paid_amount_trans,
                created_by, updated_by
            ) VALUES (
                p_client_id, p_company_id, p_location_id,
                p_trans_no, p_trans_date, v_header.voucher_type_code,
                v_line.account_id, v_line.inv_bill_no, v_line.inv_bill_date,
                v_settle_no,
                coalesce(v_was_balance, 0),
                v_line.party_amount,
                v_line.trans_amount,
                p_posted_by, p_posted_by
            );

            -- Update running settled_amount on the original invoice line
            UPDATE rid_finance_lines SET
                settled_amount = settled_amount + v_line.party_amount,
                updated_at     = now(),
                updated_by     = p_posted_by
            WHERE client_id   = p_client_id
              AND company_id  = p_company_id
              AND location_id = p_location_id
              AND trans_no    = v_line.inv_bill_no
              AND trans_date  = v_line.inv_bill_date
              AND account_id  = v_line.account_id
              AND is_deleted  = false;
        END LOOP;
    END IF;
END;
$$;

COMMIT;
