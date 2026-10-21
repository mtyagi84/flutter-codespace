-- ============================================================================
-- Migration 224: fix fn_settle_pos_non_cash_tenders — wrong table for
-- source_doc_type/source_doc_no/source_doc_date
-- ============================================================================
-- Real bug found live (2026-10-12), via the first-ever end-to-end E2E test
-- of a non-cash POS tender (Phase 3 of the POS E2E test plan,
-- sakal/e2e/tests/non-cash-tender.spec.js) — the FIRST time this code path
-- was exercised by anything other than a direct, hand-crafted SQL call.
-- Confirmed via direct `pg_get_functiondef` + a raw RPC call reproducing
-- the exact error PostgREST was returning as an opaque 400:
--
--   ERROR: column "source_doc_type" does not exist
--   WHERE: PL/pgSQL function fn_settle_pos_non_cash_tenders(...) line 46
--
-- The function's own lookup of the originating SALES_INVOICE voucher's
-- Customer DR line filtered `rid_finance_lines` directly by
-- `source_doc_type`/`source_doc_no`/`source_doc_date` — but those three
-- columns live on `rih_finance_headers` ONLY (the header-level traceability
-- tag), never on `rid_finance_lines` itself (which instead carries the
-- PER-LINE `source_line_type`/`source_line_no`, see CLAUDE.md's own
-- "Finance-line traceability" section). Every non-cash POS sale since
-- migration 218 shipped would have hit this same 400 — soft-failed and
-- silently swallowed client-side (pos_new_sale_screen.dart's own
-- `_saveTenderLines`, by design: a settlement failure must never undo or
-- block an already-approved sale) — meaning NO non-cash tender has ever
-- actually posted its Receipt Voucher settlement on this tenant, or
-- likely any tenant, until this fix.
--
-- Fix: join `rid_finance_lines` to its own `rih_finance_headers` (matching
-- on client_id/company_id/location_id/trans_no/trans_date, the same key
-- every other header+lines pair in this schema uses) and filter the
-- header's source_doc_type/no/date there instead — `source_line_type`/
-- `source_line_no` stay filtered on the line itself, unchanged. Full body
-- reproduced from migration 218 (the only migration that has ever defined
-- this function), per this project's own "grep every migration for the
-- current definition" rule — confirmed via pg_get_functiondef this is
-- genuinely the live definition, not superseded elsewhere.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_settle_pos_non_cash_tenders(
    p_client_id   UUID,
    p_company_id  UUID,
    p_invoice_no  TEXT,
    p_invoice_date DATE,
    p_user_id     UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_header         rih_sales_invoices%ROWTYPE;
    v_tender         RECORD;
    v_sls_trans_no   TEXT;
    v_sls_trans_date DATE;
    v_clearing_account UUID;
    v_link_key       TEXT;
    v_invoice_ccy    TEXT;
    v_base_ccy       TEXT;
    v_local_ccy      TEXT;
    v_customer_ccy   TEXT;
    v_party_rate     NUMERIC;
    v_party_ccy      TEXT;
    v_tender_rate_to_base NUMERIC;
    v_receipt_no     TEXT;
BEGIN
    SELECT * INTO v_header FROM rih_sales_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date;

    IF NOT FOUND OR v_header.status != 'APPROVED' THEN
        RETURN;
    END IF;

    -- Idempotency guard — never settle the same tender line twice.
    IF EXISTS (
        SELECT 1 FROM rih_finance_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND source_doc_type = 'POS_TENDER' AND source_doc_no = p_invoice_no
    ) THEN
        RETURN;
    END IF;

    SELECT currency_id INTO v_invoice_ccy FROM rim_currencies WHERE id = v_header.invoice_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    SELECT c.currency_id INTO v_customer_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.customer_id;

    -- The SLS voucher's own Customer DR line is what every settlement
    -- (cash or non-cash) must tag inv_bill_no/date against — its real
    -- trans_no is NOT p_invoice_no (SLS has its own numbering sequence,
    -- see migration 090's own header comment), so it must be looked up.
    -- FIX (224): source_doc_type/source_doc_no/source_doc_date live on
    -- rih_finance_headers, not rid_finance_lines — join to the header to
    -- filter them; source_line_type/source_line_no stay on the line.
    SELECT l.trans_no, l.trans_date INTO v_sls_trans_no, v_sls_trans_date
    FROM rid_finance_lines l
    JOIN rih_finance_headers h
      ON h.client_id = l.client_id AND h.company_id = l.company_id
     AND h.location_id = l.location_id AND h.trans_no = l.trans_no AND h.trans_date = l.trans_date
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND h.source_doc_type = 'SALES_INVOICE' AND h.source_doc_no = p_invoice_no AND h.source_doc_date = p_invoice_date
      AND l.source_line_type = 'CUSTOMER' AND l.source_line_no = 0
    LIMIT 1;

    IF v_sls_trans_no IS NULL THEN
        RETURN;  -- invoice has no customer DR line at all (shouldn't happen on an APPROVED invoice) — nothing to settle against
    END IF;

    FOR v_tender IN
        SELECT * FROM rid_pos_tender_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date AND is_deleted = false
          AND tender_type != 'CASH' AND status = 'SUCCESS'
        ORDER BY serial_no
    LOOP
        v_link_key := CASE v_tender.tender_type
            WHEN 'CARD'         THEN 'CARD_CLEARING_ACCOUNT'
            WHEN 'MOBILE_MONEY'  THEN 'MOBILE_MONEY_CLEARING_ACCOUNT'
            WHEN 'VOUCHER'       THEN 'VOUCHER_CLEARING_ACCOUNT'
            WHEN 'GIFT_CARD'     THEN 'GIFT_CARD_LIABILITY_ACCOUNT'
            WHEN 'STORE_CREDIT'  THEN 'STORE_CREDIT_LIABILITY_ACCOUNT'
        END;
        v_clearing_account := fn_resolve_company_account_link(p_client_id, p_company_id, v_link_key);
        IF v_clearing_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = format('No %s configured — ask an admin to set it up in Account Link Setup before this tender method can settle.', v_link_key);
        END IF;

        -- Rate from the tender's own currency to base, then resolve the
        -- customer's party rate against the tender's own currency (this
        -- receipt's trans_currency) — same per-receipt-currency rate
        -- resolution fn_approve_sales_invoice's own cash-collection block
        -- already uses, just keyed on the tender line's currency instead
        -- of always local/base. v_tender.rate_to_local/amount_local
        -- (stored at Charge time for the split-tender UI's own "≈ local"
        -- display) are reused here directly for the GL line's own
        -- local_amount/local_rate — same values, no need to recompute.
        v_tender_rate_to_base := CASE
            WHEN v_tender.currency_id = v_base_ccy THEN 1
            ELSE fn_get_exchange_rate(p_company_id, v_header.location_id, v_tender.currency_id, v_base_ccy, p_invoice_date)
        END;
        IF v_customer_ccy IS NULL OR v_customer_ccy = v_tender.currency_id THEN
            v_party_rate := 1; v_party_ccy := v_tender.currency_id;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_tender.currency_id, v_customer_ccy, p_invoice_date);
            v_party_ccy := v_customer_ccy;
        END IF;

        v_receipt_no := fn_save_finance_voucher(
            jsonb_build_object(
                'client_id', p_client_id, 'company_id', p_company_id, 'location_id', v_header.location_id,
                'trans_no', NULL, 'trans_date', p_invoice_date,
                'voucher_type_code', 'CRV', 'is_on_account', false,
                'remarks', format('%s settlement against Sales Invoice %s', v_tender.tender_type, p_invoice_no)
            ),
            jsonb_build_array(
                jsonb_build_object(
                    'serial_no', 1, 'account_id', v_clearing_account,
                    'trans_nature', 'DR', 'trans_amount', v_tender.amount, 'trans_currency', v_tender.currency_id,
                    'base_amount', v_tender.amount * v_tender_rate_to_base, 'base_rate', v_tender_rate_to_base,
                    'local_amount', v_tender.amount_local, 'local_rate', v_tender.rate_to_local,
                    'party_amount', v_tender.amount, 'party_currency', v_tender.currency_id, 'party_rate', 1
                ),
                jsonb_build_object(
                    'serial_no', 2, 'account_id', v_header.customer_id,
                    'trans_nature', 'CR', 'trans_amount', v_tender.amount, 'trans_currency', v_tender.currency_id,
                    'base_amount', v_tender.amount * v_tender_rate_to_base, 'base_rate', v_tender_rate_to_base,
                    'local_amount', v_tender.amount_local, 'local_rate', v_tender.rate_to_local,
                    'party_amount', v_tender.amount * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
                    'inv_bill_no', v_sls_trans_no, 'inv_bill_date', v_sls_trans_date
                )
            ),
            p_user_id
        );

        UPDATE rih_finance_headers SET
            source_doc_type = 'POS_TENDER', source_doc_no = p_invoice_no, source_doc_date = p_invoice_date
        WHERE client_id = p_client_id AND company_id = p_company_id AND location_id = v_header.location_id
          AND trans_no = v_receipt_no AND trans_date = p_invoice_date;

        PERFORM fn_post_finance_voucher(p_client_id, p_company_id, v_header.location_id, v_receipt_no, p_invoice_date, p_user_id);
    END LOOP;
END;
$$;
GRANT EXECUTE ON FUNCTION fn_settle_pos_non_cash_tenders(UUID, UUID, TEXT, DATE, UUID) TO authenticated;
