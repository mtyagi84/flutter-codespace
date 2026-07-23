-- ============================================================
-- 106_contra_voucher.sql — Contra Voucher (Finance)
--
-- A pure Cash/Bank-to-Cash/Bank transfer: Cash↔Cash, Bank↔Bank,
-- Cash→Bank (deposit), Bank→Cash (withdrawal). Never touches a
-- Customer/Supplier/General account, never affects P&L. This is
-- Tally's "Contra Voucher" (F4) — the natural next piece given this
-- app already borrows Tally's CRV/BRV/CPV/BPV/JV vocabulary.
--
-- Screen design (agreed with the user before this was written):
-- a two-block From/To layout, NOT a JV-style free-form line grid —
-- direction (Dr/Cr) is always implicit (FROM=CR, TO=DR), never a
-- field the user picks. From-amount and To-amount are two
-- INDEPENDENTLY editable fields (an idea taken from Odoo's own
-- Internal Transfer, which lets the user type the actual amount
-- credited rather than trusting a locked one-way rate multiply) —
-- when they don't reconcile at the current rate, the gap is a REAL
-- accounting event (a bank fee, or an actual rate difference) that
-- must be posted, not silently dropped; the Flutter screen computes
-- that gap live and offers an (idea taken from Zoho Books' Transfer
-- Charge) optional third line to absorb it, defaulting to whatever
-- EXCHANGE_GAIN_LOSS_ACCOUNT resolves to via the EXISTING
-- fn_resolve_company_account_link (104_cash_receipt.sql) — no new
-- account-link type needed, and freely re-pickable per transaction
-- to cover "it's really a bank fee, not FX" without adding a second
-- link type just for that.
--
-- Zero new posting logic needed. fn_save_finance_voucher/
-- fn_post_finance_voucher (105_journal_voucher.sql) already handle
-- an arbitrary N-line, any-account-nature voucher generically — a
-- 2-or-3-line Cash/Bank(-only) voucher posts through unchanged, same
-- as JV's own free-form General/Customer/Supplier lines did.
--
-- One real backend change: fn_reverse_journal_voucher (105) turns out
-- to have ZERO JV-specific logic in its body — renamed here to
-- fn_reverse_voucher so Contra can reuse the identical one-click
-- reversal Journal Voucher already has, rather than duplicating it.
-- ============================================================


-- ── 1. rim_voucher_types — allow 'CONTRA' as a voucher_nature ───────────
-- The 017 definition (RECEIPT|PAYMENT|JOURNAL|DEBIT_NOTE|CREDIT_NOTE|STOCK)
-- is NOT the current one — this constraint has already been widened twice
-- since: migration 031 added PURCHASE, migration 081 added SALES on top
-- of that (081 is the latest/authoritative version). Re-deriving from 017
-- alone (as an earlier draft of this migration did) silently NARROWS the
-- constraint back and breaks every PURCHASE/SALES-natured system voucher
-- type already live (PO-LOC, GRN, PINV, SQ, SO, SI, ... — caught live via
-- "check constraint ... is violated by some row" the moment this ran
-- against real data). Extends the REAL current list, not the original one.
ALTER TABLE rim_voucher_types DROP CONSTRAINT IF EXISTS rim_voucher_types_nature_check;
ALTER TABLE rim_voucher_types ADD CONSTRAINT rim_voucher_types_nature_check
    CHECK (voucher_nature IN ('RECEIPT','PAYMENT','JOURNAL','DEBIT_NOTE','CREDIT_NOTE','STOCK','PURCHASE','SALES','CONTRA'));

-- cash_bank_side is deliberately NULL, same reasoning as JV's own row:
-- a Contra voucher has TWO cash/bank legs (one DR, one CR simultaneously),
-- so "which side is the cash/bank leg" has no single answer the way it
-- does for CRV/BRV (always DR) or CPV/BPV (always CR). Direction is
-- computed in the Flutter screen (FROM=CR, TO=DR, always, never a user
-- choice), not driven by this column — confirmed voucher_logic.dart's
-- line1Nature()/counterNature() helpers are pure per-type-code functions,
-- not readers of this column, so leaving it NULL changes nothing there.
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('CTR', 'Contra Voucher', 'CONTRA', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ── 2. Menu seed for EXISTING clients ────────────────────────────────
-- fn_seed_client_modules.sql (backend/functions/) has been updated to
-- seed 'FN-CTR' for FUTURE new clients (that file must be re-run
-- manually in the Supabase SQL editor — it only runs at
-- fn_register_client time, per the standing "Supabase Function
-- Deployment Gap" convention). This backfills every already-existing
-- company, same shape as migration 092/095's own menu-wiring retrofits.
--
-- IMPORTANT: adding this row alone does not grant any existing user
-- access — re-run fn_grant_admin_access(user_id, client_id, company_id)
-- for whichever user(s) should see this screen (idempotent, safe to
-- re-run), or grant access manually via the User Permissions screen.
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT
    co.client_id, co.id, sm.id, 'FN-CTR', 'Contra Voucher', '/finance/contra',
    1, 'FN-TXN', 'Transactions', 0,
    true, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'FN'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;


-- ── 3. fn_reverse_journal_voucher → fn_reverse_voucher (rename) ─────────
-- Re-read directly before renaming: the existing body has no
-- voucher_type_code check anywhere — it locks the header, validates
-- posted + not-already-reversed, flips every line's Dr/Cr, drops
-- inv_bill_no/inv_bill_date, and re-posts under the ORIGINAL voucher's
-- own voucher_type_code via fn_save_finance_voucher+fn_post_finance_
-- voucher. Already fully generic; only the name was JV-specific.
-- Identical body, new name, so both JV and Contra Voucher share ONE
-- reversal engine — this app's own "shared posting engines, never
-- duplicate" convention.
DROP FUNCTION IF EXISTS fn_reverse_journal_voucher(UUID, UUID, TEXT, DATE, UUID);

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
            'party_amount',   v_line.party_amount,  'party_currency', v_line.party_currency, 'party_rate', v_line.party_rate,
            'line_remarks',   v_line.line_remarks
        ));
    END LOOP;

    IF jsonb_array_length(v_lines) = 0 THEN
        RAISE EXCEPTION 'Voucher % has no lines to reverse.', p_trans_no;
    END IF;

    v_new_trans_no := fn_save_finance_voucher(
        jsonb_build_object(
            'client_id',         p_client_id,
            'company_id',        p_company_id,
            'location_id',       v_header.location_id,
            'trans_no',          NULL,
            'trans_date',        CURRENT_DATE,
            'voucher_type_code', v_header.voucher_type_code,
            'is_on_account',     true,
            'remarks',           format('Reversal of %s dated %s', p_trans_no, p_trans_date)
        ),
        v_lines,
        p_user_id
    );

    PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_new_trans_no, CURRENT_DATE, p_user_id);

    UPDATE rih_finance_headers SET
        reversal_of_trans_no = p_trans_no,
        updated_at = now(), updated_by = p_user_id
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND trans_no = v_new_trans_no AND trans_date = CURRENT_DATE;

    RETURN v_new_trans_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_reverse_voucher(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
