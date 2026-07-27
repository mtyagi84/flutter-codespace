-- ============================================================
-- 108_finance_voucher_approve_permission.sql
--
-- Real security gap found in a 2026-07-27 QA-checklist pass: the Flutter
-- UI gates the Approve button via ScreenPermissionMixin's canApprove
-- (from a menu-permissions list cached at login), but the backend never
-- re-checked it — fn_post_finance_voucher (Journal/Contra Voucher's own
-- approve path), fn_approve_expense_voucher, and fn_reverse_voucher only
-- ever checked document status + period/backdate, never ric_user_menus.
--
-- Design decisions:
-- 1. The user being checked is resolved from the JWT's own signed
--    'user_id' claim (current_setting('request.jwt.claims')), never from
--    the client-supplied p_posted_by/p_approved_by/p_user_id parameter —
--    checking against a client-supplied value would be trivially
--    bypassable by sending a different user's id in the RPC payload.
-- 2. No JWT context at all (direct SQL / pgTAP / migrations, the same
--    "trusted caller" class that already bypasses RLS) skips the check
--    rather than denying — keeps every existing 105/106/107 pgTAP
--    assertion passing unchanged; a NEW test proves the real enforcement
--    path when a JWT *is* present (108_finance_voucher_approve_permission_test.sql).
--
-- Every CREATE OR REPLACE below reproduces the function's CURRENT full
-- body verbatim (read directly from 105/106/107, not paraphrased) with
-- only the new permission-check lines inserted — same signature in every
-- case, so this is a safe in-place replace per this project's own
-- "OR REPLACE is safe when signature is unchanged" rule.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_check_approve_permission(
    p_client_id    UUID,
    p_company_id   UUID,
    p_feature_code TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_jwt_user_id  UUID;
    v_allowed      BOOLEAN;
    v_feature_name TEXT;
BEGIN
    BEGIN
        v_jwt_user_id := (current_setting('request.jwt.claims', true)::json->>'user_id')::uuid;
    EXCEPTION WHEN OTHERS THEN
        v_jwt_user_id := NULL;
    END;

    -- No JWT context at all (direct SQL, pgTAP, a migration) — nothing to
    -- enforce; this is the same trust boundary RLS itself already assumes.
    IF v_jwt_user_id IS NULL THEN
        RETURN;
    END IF;

    SELECT um.approve_allowed INTO v_allowed
    FROM ric_user_menus um
    WHERE um.client_id    = p_client_id
      AND um.company_id   = p_company_id
      AND um.user_id      = v_jwt_user_id
      AND um.feature_code = p_feature_code
      AND um.is_deleted   = false
      AND um.is_active    = true;

    IF v_allowed IS NOT TRUE THEN
        SELECT mm.feature_name INTO v_feature_name
        FROM ric_master_menus mm
        WHERE mm.client_id = p_client_id AND mm.company_id = p_company_id AND mm.feature_code = p_feature_code
        LIMIT 1;

        RAISE EXCEPTION 'APPROVE_NOT_PERMITTED'
            USING DETAIL = format('You do not have permission to approve %s.', COALESCE(v_feature_name, p_feature_code));
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_check_approve_permission(UUID, UUID, TEXT) TO authenticated;

-- ════════════════════════════════════════════════════════════════════
-- fn_post_finance_voucher — Journal Voucher (JV) + Contra Voucher (CTR).
-- Full body reproduced verbatim from 105_journal_voucher.sql; only the
-- new IF block right after the is_posted check is new.
--
-- Payment/Receipt Voucher (CRV/BRV/CPV/BPV) also calls this shared
-- engine, but grepping the whole backend found NO seeded feature_code/
-- screen_name row for that screen (/finance/voucher-list) in
-- fn_seed_client_modules.sql or any migration — its own client-side
-- _findFeature() already returns null and blocks the screen for every
-- client. A separate, pre-existing menu-wiring gap, not something to
-- paper over with a guessed mapping here — left as a no-op (falls
-- through the IF/ELSIF untouched), flagged, not silently "fixed".
-- ════════════════════════════════════════════════════════════════════
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
    v_bad_account   text;
BEGIN
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

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never the p_posted_by parameter) — see migration header comment.
    IF v_header.voucher_type_code = 'JV' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
    ELSIF v_header.voucher_type_code = 'CTR' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
    END IF;

    PERFORM fn_check_period_open(p_company_id, p_trans_date);

    -- Backdate check, reference-dated to when this voucher was actually
    -- created — never blocks approving a same-day-created voucher just
    -- because "today" moved on since it was saved.
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'FINANCE_VOUCHER', p_trans_date, v_header.created_at::date);

    SELECT a.account_code INTO v_bad_account
    FROM rid_finance_lines l
    JOIN rim_accounts a ON a.id = l.account_id
    WHERE l.client_id   = p_client_id
      AND l.company_id  = p_company_id
      AND l.location_id = p_location_id
      AND l.trans_no    = p_trans_no
      AND l.trans_date  = p_trans_date
      AND l.is_deleted  = false
      AND a.posting_allowed = false
    LIMIT 1;

    IF v_bad_account IS NOT NULL THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_POSTABLE'
            USING DETAIL = format('Account %s is a group/header account and cannot receive postings.', v_bad_account);
    END IF;

    SELECT abs(sum(
        CASE WHEN trans_nature = 'DR' THEN base_amount ELSE -base_amount END
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

    IF v_header.cheque_no IS NOT NULL THEN
        INSERT INTO rid_cheque_register (
            client_id, company_id, location_id,
            trans_no, trans_date,
            cheque_no, cheque_date,
            cheque_status, created_by, updated_by
        ) VALUES (
            p_client_id, p_company_id, p_location_id,
            p_trans_no, p_trans_date,
            v_header.cheque_no,
            COALESCE(v_header.cheque_date, v_header.trans_date),
            'ISSUED', p_posted_by, p_posted_by
        )
        ON CONFLICT DO NOTHING;
    END IF;

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

-- ════════════════════════════════════════════════════════════════════
-- fn_approve_expense_voucher — dedicated function, always FN-EXP.
-- Full body reproduced verbatim from 107_expense_voucher.sql; only the
-- new PERFORM line right after the status check is new.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_expense_voucher(
    p_client_id   UUID,
    p_company_id  UUID,
    p_location_id UUID,
    p_trans_no    TEXT,
    p_trans_date  DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header         rih_expense_voucher_headers%ROWTYPE;
    v_line           RECORD;
    v_tax_row        RECORD;
    v_currency_ccy   TEXT;
    v_base_ccy       TEXT;
    v_local_ccy      TEXT;
    v_account_ccy    TEXT;
    v_party_rate     NUMERIC;
    v_party_ccy      TEXT;
    v_rate           NUMERIC;
    v_tax_amt        NUMERIC;
    v_other_lines    JSONB := '[]'::jsonb;
    v_voucher_lines  JSONB;
    v_dr_total_trans NUMERIC := 0;
    v_dr_total_base  NUMERIC := 0;
    v_wht_total_trans NUMERIC := 0;
    v_wht_total_base  NUMERIC := 0;
    v_net_trans      NUMERIC;
    v_net_base       NUMERIC;
    v_voucher_result RECORD;
BEGIN
    -- 1. Lock header, validate status.
    SELECT * INTO v_header FROM rih_expense_voucher_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND trans_no = p_trans_no AND trans_date = p_trans_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Expense Voucher % dated % not found', p_trans_no, p_trans_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Expense Voucher % is % and cannot be approved again', p_trans_no, v_header.status;
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never the p_approved_by parameter) — see migration header comment.
    PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-EXP');

    -- 2. Period + backdate checks (5-arg form — compares against this
    --    document's own creation date, not live CURRENT_DATE, same fix
    --    Journal Voucher's own backdate check got in migration 105).
    PERFORM fn_check_period_open(p_company_id, p_trans_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'EXPENSE_VOUCHER', p_trans_date, v_header.created_at::date);

    SELECT currency_id INTO v_currency_ccy FROM rim_currencies WHERE id = v_header.currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- 3. Loop expense lines — each is always an implicit DEBIT (no manual
    --    Dr/Cr, per the user's own final direction), with an optional Tax
    --    Group expanded into further lines.
    FOR v_line IN
        SELECT * FROM rid_expense_voucher_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND trans_no = p_trans_no AND trans_date = p_trans_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_line.account_id;
        IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
            v_party_rate := 1; v_party_ccy := v_currency_ccy;
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_other_lines := v_other_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_line.account_id, 'trans_nature', 'DR',
            'trans_amount', v_line.amount, 'trans_currency', v_currency_ccy,
            'base_amount', v_line.amount * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_line.amount * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_line.amount * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'line_remarks', v_line.line_remarks, 'source_line_type', 'EXPENSE', 'source_line_no', v_line.serial_no
        ));
        v_dr_total_trans := v_dr_total_trans + v_line.amount;
        v_dr_total_base  := v_dr_total_base  + (v_line.amount * v_header.rate_to_base);

        -- Tax Group expansion — a normal (VAT-type) member ADDS to the
        -- payable, a WITHHOLDING-type member SUBTRACTS from it. First real
        -- consumer of rim_tax_types.is_withholding anywhere in this schema.
        IF v_line.tax_group_id IS NOT NULL THEN
            FOR v_tax_row IN
                SELECT t.id AS tax_id, t.tax_code, t.tax_name,
                       t.gl_input_account_id, t.gl_expense_account_id,
                       tt.is_withholding
                FROM rim_tax_group_members tgm
                JOIN rim_taxes t      ON t.id = tgm.tax_id
                JOIN rim_tax_types tt ON tt.tax_type_code = t.tax_type_code
                WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                  AND tgm.tax_group_id = v_line.tax_group_id
                ORDER BY tgm.sequence_no
            LOOP
                v_rate := fn_get_active_tax_rate(v_tax_row.tax_id, p_trans_date);
                IF v_rate IS NULL THEN
                    RAISE EXCEPTION 'TAX_RATE_NOT_CONFIGURED'
                        USING DETAIL = format('Tax [%s] %s has no active rate for %s.', v_tax_row.tax_code, v_tax_row.tax_name, p_trans_date);
                END IF;
                v_tax_amt := v_line.amount * v_rate / 100;
                IF v_tax_amt = 0 THEN
                    CONTINUE;
                END IF;

                IF NOT v_tax_row.is_withholding THEN
                    IF v_tax_row.gl_input_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Tax [%s] %s has no Input GL account configured.', v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;

                    SELECT c.currency_id INTO v_account_ccy
                    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
                    WHERE a.id = v_tax_row.gl_input_account_id;
                    IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
                        v_party_rate := 1; v_party_ccy := v_currency_ccy;
                    ELSIF v_account_ccy = v_base_ccy THEN
                        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
                    ELSIF v_account_ccy = v_local_ccy THEN
                        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
                    ELSE
                        v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
                        v_party_ccy := v_account_ccy;
                    END IF;

                    v_other_lines := v_other_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'DR',
                        'trans_amount', v_tax_amt, 'trans_currency', v_currency_ccy,
                        'base_amount', v_tax_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_tax_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_tax_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
                        'source_line_type', 'INPUT_VAT', 'source_line_no', v_line.serial_no
                    ));
                    v_dr_total_trans := v_dr_total_trans + v_tax_amt;
                    v_dr_total_base  := v_dr_total_base  + (v_tax_amt * v_header.rate_to_base);
                ELSE
                    IF v_tax_row.gl_expense_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Withholding tax [%s] %s has no GL account configured.', v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;

                    SELECT c.currency_id INTO v_account_ccy
                    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
                    WHERE a.id = v_tax_row.gl_expense_account_id;
                    IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
                        v_party_rate := 1; v_party_ccy := v_currency_ccy;
                    ELSIF v_account_ccy = v_base_ccy THEN
                        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
                    ELSIF v_account_ccy = v_local_ccy THEN
                        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
                    ELSE
                        v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
                        v_party_ccy := v_account_ccy;
                    END IF;

                    v_other_lines := v_other_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_expense_account_id, 'trans_nature', 'CR',
                        'trans_amount', v_tax_amt, 'trans_currency', v_currency_ccy,
                        'base_amount', v_tax_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_tax_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_tax_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
                        'source_line_type', 'WITHHOLDING', 'source_line_no', v_line.serial_no
                    ));
                    v_wht_total_trans := v_wht_total_trans + v_tax_amt;
                    v_wht_total_base  := v_wht_total_base  + (v_tax_amt * v_header.rate_to_base);
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    -- 4. Supplier CR line — net = expense+VAT total minus withholding
    --    total. base_amount is FORCED to the literal accumulated figure
    --    (never re-derived via trans_amount * rate_to_base independently)
    --    so fn_post_voucher's own DR=CR check can never fail on a
    --    floating-point rounding mismatch — same technique 059 uses for
    --    its own PUR voucher.
    v_net_trans := v_dr_total_trans - v_wht_total_trans;
    v_net_base  := v_dr_total_base  - v_wht_total_base;

    IF v_net_base <= 0 THEN
        RAISE EXCEPTION 'EXPENSE_NET_NOT_POSITIVE'
            USING DETAIL = 'The Debit total must exceed the Credit total — this document creates a payable, so the supplier must end up owed a positive amount.';
    END IF;

    SELECT c.currency_id INTO v_account_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.supplier_id;
    IF v_account_ccy IS NULL OR v_account_ccy = v_currency_ccy THEN
        v_party_rate := 1; v_party_ccy := v_currency_ccy;
    ELSIF v_account_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_account_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, p_location_id, v_currency_ccy, v_account_ccy, p_trans_date);
        v_party_ccy := v_account_ccy;
    END IF;

    -- Supplier is prepended first — fn_post_voucher assigns serial_no in
    -- array order, so this guarantees Supplier = serial_no 1, matching
    -- Payment/Receipt Voucher's own "line 1 is the fixed/anchor line"
    -- convention, even though it's computed last.
    v_voucher_lines := jsonb_build_array(jsonb_build_object(
        'account_id', v_header.supplier_id, 'trans_nature', 'CR',
        'trans_amount', v_net_trans, 'trans_currency', v_currency_ccy,
        'base_amount', v_net_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_net_trans * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_net_trans * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', v_header.bill_no, 'inv_bill_date', v_header.bill_date,
        'source_line_type', 'SUPPLIER'
    )) || v_other_lines;

    -- 5. Post — fn_post_voucher composes fn_save_finance_voucher +
    --    fn_post_finance_voucher, tags source_doc_type/no/date, and
    --    re-validates DR=CR on base_amount itself. Posts under 'EXP'
    --    (the posting code), never 'EXV' (the document's own numbering
    --    code) — see the rim_voucher_types seed comment above.
    SELECT * INTO v_voucher_result FROM fn_post_voucher(
        p_client_id, p_company_id, p_location_id, 'EXP', p_trans_date,
        v_voucher_lines, 'EXPENSE_VOUCHER', p_trans_no, p_trans_date, p_approved_by
    );

    -- 6. Mark approved, store GL traceability.
    UPDATE rih_expense_voucher_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_voucher_result.trans_no,
        posted_voucher_date = v_voucher_result.trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

-- ════════════════════════════════════════════════════════════════════
-- fn_reverse_voucher — shared by JV/CTR/EXP, arguably more sensitive than
-- approve itself since it undoes a real GL posting. Full body reproduced
-- verbatim from 106_contra_voucher.sql; only the new IF block right
-- after the ALREADY_REVERSED check is new.
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_reverse_voucher(
    p_client_id   UUID,
    p_company_id  UUID,
    p_trans_no    TEXT,
    p_trans_date  DATE,
    p_user_id     UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_header       rih_finance_headers%ROWTYPE;
    v_line         rid_finance_lines%ROWTYPE;
    v_lines        JSONB := '[]'::jsonb;
    v_serial       INTEGER := 0;
    v_new_trans_no TEXT;
BEGIN
    SELECT * INTO v_header FROM rih_finance_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND trans_no = p_trans_no AND trans_date = p_trans_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher % dated % not found', p_trans_no, p_trans_date;
    END IF;
    IF NOT v_header.is_posted THEN
        RAISE EXCEPTION 'NOT_POSTED' USING DETAIL = 'Only a posted voucher can be reversed.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM rih_finance_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND reversal_of_trans_no = p_trans_no AND is_deleted = false
    ) THEN
        RAISE EXCEPTION 'ALREADY_REVERSED'
            USING DETAIL = format('Voucher %s has already been reversed.', p_trans_no);
    END IF;

    -- NEW: server-side re-check of approve permission, resolved from the
    -- JWT (never the p_user_id parameter) — see migration header comment.
    -- Expense Voucher's own posted GL entry carries voucher_type_code
    -- 'EXP' (the posting code, not 'EXV' the document-numbering code).
    IF v_header.voucher_type_code = 'JV' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-JRN');
    ELSIF v_header.voucher_type_code = 'CTR' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-CTR');
    ELSIF v_header.voucher_type_code = 'EXP' THEN
        PERFORM fn_check_approve_permission(p_client_id, p_company_id, 'FN-EXP');
    END IF;

    PERFORM fn_check_period_open(p_company_id, CURRENT_DATE);

    FOR v_line IN
        SELECT * FROM rid_finance_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND trans_no = p_trans_no AND trans_date = p_trans_date AND is_deleted = false
        ORDER BY serial_no
    LOOP
        v_serial := v_serial + 1;
        -- Deliberately NOT carrying inv_bill_no/inv_bill_date forward —
        -- a reversal is a pure GL correction, never a new bill.
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
            'serial_no',      v_serial,
            'account_id',     v_line.account_id,
            'trans_nature',   CASE WHEN v_line.trans_nature = 'DR' THEN 'CR' ELSE 'DR' END,
            'trans_amount',   v_line.trans_amount,  'trans_currency', v_line.trans_currency,
            'base_amount',    v_line.base_amount,   'base_rate',      v_line.base_rate,
            'local_amount',   v_line.local_amount,  'local_rate',     v_line.local_rate,
            'party_amount',   v_line.party_amount,  'party_currency', v_line.party_currency,
            'party_rate',     v_line.party_rate,
            'line_remarks',   'Reversal of ' || p_trans_no
        ));
    END LOOP;

    v_new_trans_no := fn_save_finance_voucher(
        jsonb_build_object(
            'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
            'trans_no', null, 'trans_date', CURRENT_DATE,
            'voucher_type_code', v_header.voucher_type_code, 'is_on_account', v_header.is_on_account,
            'reversal_of_trans_no', p_trans_no,
            'remarks', 'Reversal of ' || p_trans_no
        ),
        v_lines,
        p_user_id
    );

    PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_new_trans_no, CURRENT_DATE, p_user_id);

    RETURN v_new_trans_no;
END;
$$;
