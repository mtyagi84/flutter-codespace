-- ============================================================
-- Migration 054: Purchase Bill (Purchase Invoice)
-- ============================================================
-- Clears the Purchase Accrual each GRN provisionally credited (migration
-- 050's GR/IR pattern), recognizes the REAL Input VAT (deliberately
-- deferred at GRN time — see 050's header comment), books the REAL
-- Supplier payable, and absorbs any GRN-rate-vs-bill-rate FX movement
-- into a dedicated Exchange Gain/Loss account. Matches the SAP MIRO /
-- Oracle Payables "match to receipt" GR/IR clearing pattern, adapted to
-- this project's existing account-link + shared-voucher-engine design —
-- confirmed against both in the design discussion this migration was
-- built from.
--
-- One supplier per bill, one currency per bill (GRNs of a different
-- currency are filtered out at the picker, same convention as GRN's own
-- "pick currency, then pick POs" step) — a vendor invoice is always one
-- document in one currency in every ERP checked.
--
-- No new line-items table: a GRN either belongs to a bill or it doesn't
-- (whole-GRN billing only, no partial-GRN split across bills, agreed as
-- the v1 scope). rih_grn_headers.billed_invoice_no/date IS the linkage —
-- doubles as the "already billed" flag AND the "which GRNs are in bill X"
-- answer (a plain WHERE clause, no junction table), mirroring how GRN
-- itself stamps posted_voucher_no/date back after its own posting. The
-- same two columns get set at DRAFT save time already (reserving the GRN
-- against this bill so two draft bills can't both claim it), not just at
-- Approve — cleared and re-set on every DRAFT edit, exactly like GRN's
-- own delete+reinsert-on-edit pattern for its child rows.
--
-- GL posting (fn_approve_purchase_invoice), all resolved via
-- fn_resolve_account_link / rim_taxes' own GL links — nothing new
-- invented except the two account-link types this migration seeds:
--   DR Purchase Accrual (one line PER distinct account+GRN, replicated
--       exactly from each linked GRN's own ACCRUAL lines in
--       rid_finance_lines — NOT a lump sum, since PURCHASE_ACCRUAL_ACCOUNT
--       can resolve differently per product/category, so only replicating
--       the exact original lines guarantees the clearing is exact)
--   DR Input VAT, apportioned two levels deep: first across the linked
--       GRNs' own lines by each line's share of the total ESTIMATED tax
--       (rid_grn_lines.tax_amount) that was never posted, then within
--       each line across its tax_group's member taxes by rate weight
--       (fn_get_active_tax_rate) — same weighting fn_approve_grn itself
--       used to use before VAT deferral (050), now applied to the REAL
--       lump-sum VAT amount entered from the supplier's paper invoice —
--       to each tax's own gl_input_account_id.
--   CR Supplier Account = real invoice total, at the BILL's own rate —
--       tagged inv_bill_no/inv_bill_date = the SUPPLIER's own invoice
--       number/date (not our internal invoice_no) so this payable rides
--       the existing, already-working "pending bills against this party"
--       mechanism (020_pending_bills_view.sql is fully generic — any
--       rid_finance_lines row with inv_bill_no set) for free, wiring
--       straight into Payment Voucher's Against Bill settlement with zero
--       changes there.
--   DR/CR Exchange Gain/Loss = whatever the above three don't balance to
--       — the GRN-rate-vs-bill-rate gap on the accrual amount, resolved
--       via EXCHANGE_GAIN_LOSS_ACCOUNT (seeded in 032, never used until
--       now) anchored on any one product from the linked GRN lines (this
--       account is realistically always configured at COMPANY
--       granularity, never per-item, so the anchor choice is immaterial).
-- ============================================================

-- ── New account-link type: Input VAT ─────────────────────────────────────────
-- EXCHANGE_GAIN_LOSS_ACCOUNT already exists (032) but has never been
-- resolved by any function until this one.
INSERT INTO rim_account_link_types (link_key, link_name, sort_order) VALUES
    ('INPUT_VAT_ACCOUNT', 'Input VAT Account', 140)
ON CONFLICT (link_key) DO NOTHING;

-- ── Seed 'PINV' voucher type (needed by fn_next_trans_no) ───────────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('PINV', 'Purchase Invoice (Bill)', 'PURCHASE', NULL, 'YEARLY', 'PINV/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

-- ── rih_grn_headers: billing linkage ─────────────────────────────────────────
ALTER TABLE rih_grn_headers
    ADD COLUMN IF NOT EXISTS billed_invoice_no   TEXT,
    ADD COLUMN IF NOT EXISTS billed_invoice_date DATE;

CREATE INDEX IF NOT EXISTS idx_grn_headers_billed
    ON rih_grn_headers (client_id, company_id, supplier_id, billed_invoice_no)
    WHERE is_deleted = false;

-- ── rih_purchase_invoices ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_purchase_invoices (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL REFERENCES ric_clients(id),
    company_id             UUID          NOT NULL REFERENCES ric_companies(id),
    location_id            UUID          NOT NULL REFERENCES ric_locations(id),
    invoice_no             TEXT          NOT NULL,   -- our own document number (PINV/...)
    invoice_date           DATE          NOT NULL,
    supplier_id            UUID          NOT NULL REFERENCES rim_accounts(id),
    -- The supplier's own paper invoice — the actual document being matched.
    -- Duplicate prevention lives on this pair, not on our internal invoice_no.
    supplier_invoice_no    TEXT          NOT NULL,
    supplier_invoice_date  DATE          NOT NULL,
    invoice_currency_id    UUID          NOT NULL REFERENCES rim_currencies(id),
    rate_to_base           NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local          NUMERIC(18,8) NOT NULL DEFAULT 1,
    -- User-entered from the supplier's paper invoice, in invoice_currency_id.
    taxable_amount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount             NUMERIC(18,4) NOT NULL DEFAULT 0,
    invoice_total          NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- Finalized at Approve only (0 while DRAFT) — signed: positive = loss
    -- (posted DR), negative = gain (posted CR).
    exchange_diff_base     NUMERIC(18,4) NOT NULL DEFAULT 0,
    remarks                TEXT,
    status                 TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by            UUID          REFERENCES rim_users(id),
    approved_at            TIMESTAMPTZ,
    posted_voucher_no      TEXT,
    posted_voucher_date    DATE,
    is_active              BOOLEAN       NOT NULL DEFAULT true,
    is_deleted             BOOLEAN       NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by             UUID          REFERENCES rim_users(id),
    updated_at             TIMESTAMPTZ,
    updated_by             UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, invoice_no, invoice_date),
    UNIQUE (client_id, company_id, supplier_id, supplier_invoice_no)
);

CREATE INDEX IF NOT EXISTS idx_purchase_invoices_supplier ON rih_purchase_invoices (client_id, company_id, supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_invoices_status   ON rih_purchase_invoices (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_purchase_invoices_updated_at ON rih_purchase_invoices;
CREATE TRIGGER trg_rih_purchase_invoices_updated_at
    BEFORE UPDATE ON rih_purchase_invoices
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_purchase_invoices ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_purchase_invoices" ON rih_purchase_invoices;
CREATE POLICY "auth_rw_purchase_invoices" ON rih_purchase_invoices
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_purchase_invoices FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_purchase_invoices TO authenticated;


-- ── fn_save_purchase_invoice ──────────────────────────────────────────────────
-- Draft-only. p_grn_refs = [{grn_no, grn_date}, ...] — the GRNs currently
-- checked on the entry screen. Reserves them (billed_invoice_no/date) the
-- moment a draft is saved, not just on Approve, so a second draft bill
-- can't also claim the same GRN. On edit, un-reserves the OLD set first,
-- then re-validates and re-reserves the NEW set — same delete-then-
-- reinsert shape GRN itself uses for its own child rows, just applied to
-- a marker column pair instead of a child table.
CREATE OR REPLACE FUNCTION fn_save_purchase_invoice(
    p_header   JSONB,
    p_grn_refs JSONB,
    p_user_id  UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id       UUID;
    v_company_id      UUID;
    v_location_id     UUID;
    v_supplier_id     UUID;
    v_invoice_no      TEXT;
    v_invoice_date    DATE;
    v_old_invoice_date DATE;
    v_old_status      TEXT;
    v_is_new          BOOLEAN;
    v_ref             JSONB;
    v_grn             rih_grn_headers%ROWTYPE;
BEGIN
    v_client_id    := (p_header->>'client_id')::uuid;
    v_company_id   := (p_header->>'company_id')::uuid;
    v_location_id  := (p_header->>'location_id')::uuid;
    v_supplier_id  := (p_header->>'supplier_id')::uuid;
    v_invoice_no   := nullif(trim(p_header->>'invoice_no'), '');
    v_invoice_date := (p_header->>'invoice_date')::date;
    v_is_new       := v_invoice_no IS NULL;

    IF jsonb_array_length(p_grn_refs) = 0 THEN
        RAISE EXCEPTION 'Select at least one GRN to raise a Purchase Bill.';
    END IF;

    IF v_is_new THEN
        v_invoice_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'PINV');
    ELSE
        SELECT invoice_date, status INTO v_old_invoice_date, v_old_status
        FROM rih_purchase_invoices
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Purchase Bill % is % and cannot be edited.', v_invoice_no, v_old_status;
        END IF;

        -- Un-reserve whatever this draft previously held.
        UPDATE rih_grn_headers SET billed_invoice_no = NULL, billed_invoice_date = NULL,
               updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND billed_invoice_no = v_invoice_no AND billed_invoice_date = v_old_invoice_date;
    END IF;

    -- Lock + validate each referenced GRN, one row per statement in a fixed
    -- sort order — same deadlock-avoidance rule as fn_approve_grn's PO-line
    -- locking (036/038): a single ORDER BY ... FOR UPDATE does not
    -- guarantee lock-acquisition order in Postgres.
    FOR v_ref IN
        SELECT * FROM jsonb_array_elements(p_grn_refs)
        ORDER BY value->>'grn_no', value->>'grn_date'
    LOOP
        SELECT * INTO v_grn FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_ref->>'grn_no' AND grn_date = (v_ref->>'grn_date')::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'GRN % not found.', v_ref->>'grn_no';
        END IF;
        IF v_grn.status != 'APPROVED' THEN
            RAISE EXCEPTION 'GRN % is % — only APPROVED GRNs can be billed.', v_grn.grn_no, v_grn.status;
        END IF;
        IF v_grn.supplier_id != v_supplier_id THEN
            RAISE EXCEPTION 'GRN % does not belong to the selected supplier.', v_grn.grn_no;
        END IF;
        IF v_grn.billed_invoice_no IS NOT NULL AND v_grn.billed_invoice_no != v_invoice_no THEN
            RAISE EXCEPTION 'GRN % is already on Purchase Bill %.', v_grn.grn_no, v_grn.billed_invoice_no;
        END IF;

        UPDATE rih_grn_headers SET billed_invoice_no = v_invoice_no, billed_invoice_date = v_invoice_date,
               updated_at = now(), updated_by = p_user_id
        WHERE id = v_grn.id;
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_purchase_invoices (
            client_id, company_id, location_id, invoice_no, invoice_date,
            supplier_id, supplier_invoice_no, supplier_invoice_date,
            invoice_currency_id, rate_to_base, rate_to_local,
            taxable_amount, tax_amount, invoice_total, remarks,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_invoice_no, v_invoice_date,
            v_supplier_id,
            p_header->>'supplier_invoice_no', (p_header->>'supplier_invoice_date')::date,
            (p_header->>'invoice_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'taxable_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'invoice_total')::numeric, 0),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_purchase_invoices SET
            location_id           = v_location_id,
            invoice_date           = v_invoice_date,
            supplier_id             = v_supplier_id,
            supplier_invoice_no      = p_header->>'supplier_invoice_no',
            supplier_invoice_date     = (p_header->>'supplier_invoice_date')::date,
            invoice_currency_id        = (p_header->>'invoice_currency_id')::uuid,
            rate_to_base                = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local                 = coalesce((p_header->>'rate_to_local')::numeric, 1),
            taxable_amount                 = coalesce((p_header->>'taxable_amount')::numeric, 0),
            tax_amount                       = coalesce((p_header->>'tax_amount')::numeric, 0),
            invoice_total                     = coalesce((p_header->>'invoice_total')::numeric, 0),
            remarks                            = nullif(p_header->>'remarks', ''),
            updated_at                          = now(),
            updated_by                            = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND invoice_no = v_invoice_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    RETURN v_invoice_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_purchase_invoice(JSONB, JSONB, UUID) TO authenticated;


-- ── fn_approve_purchase_invoice ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION fn_approve_purchase_invoice(
    p_client_id   UUID,
    p_company_id  UUID,
    p_invoice_no  TEXT,
    p_invoice_date DATE,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header           rih_purchase_invoices%ROWTYPE;
    v_grn              RECORD;
    v_grn_line         RECORD;
    v_tax_row          RECORD;
    v_invoice_ccy      TEXT;
    v_base_ccy         TEXT;
    v_local_ccy        TEXT;
    v_account_ccy      TEXT;
    v_party_rate       NUMERIC;
    v_party_ccy        TEXT;
    v_anchor_product_id UUID;
    v_total_est_tax    NUMERIC := 0;
    v_line_share       NUMERIC;
    v_rate_sum         NUMERIC;
    v_voucher_lines    JSONB := '[]'::jsonb;
    v_dr_total         NUMERIC := 0;
    v_cr_total         NUMERIC := 0;
    v_fx_account       UUID;
    v_fx_diff          NUMERIC;
    v_voucher_result   RECORD;
    v_supplier_trans_amt NUMERIC;
    v_grn_count        INTEGER := 0;
    v_tax_account_ccy  TEXT;
    v_tax_party_rate   NUMERIC;
    v_tax_party_ccy    TEXT;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_purchase_invoices
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND invoice_no = p_invoice_no AND invoice_date = p_invoice_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Bill % dated % not found', p_invoice_no, p_invoice_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Bill % is % and cannot be approved again', p_invoice_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_invoice_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'PURCHASE_INVOICE', p_invoice_date);

    -- 3. Lock every linked GRN, one row per statement in a fixed sort order
    --    (same rule as fn_save_purchase_invoice / fn_approve_grn).
    FOR v_grn IN
        SELECT * FROM rih_grn_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND billed_invoice_no = p_invoice_no AND billed_invoice_date = p_invoice_date
          AND is_deleted = false
        ORDER BY grn_no, grn_date
    LOOP
        PERFORM 1 FROM rih_grn_headers WHERE id = v_grn.id FOR UPDATE;
        v_grn_count := v_grn_count + 1;
    END LOOP;

    IF v_grn_count = 0 THEN
        RAISE EXCEPTION 'No GRNs are linked to Purchase Bill %.', p_invoice_no;
    END IF;

    SELECT currency_id INTO v_invoice_ccy FROM rim_currencies WHERE id = v_header.invoice_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- 4. DR Purchase Accrual — replicate each linked GRN's own ACCRUAL lines
    --    exactly (account + base_amount), never a lump sum: PURCHASE_ACCRUAL_
    --    ACCOUNT can resolve differently per product/category, so only
    --    replaying the exact original lines guarantees an exact clearing.
    FOR v_grn_line IN
        SELECT l.account_id, l.trans_amount, l.trans_currency, l.base_amount, l.base_rate,
               l.local_amount, l.local_rate, l.party_amount, l.party_currency, l.party_rate
        FROM rih_grn_headers g
        JOIN rih_finance_headers h
          ON h.client_id = g.client_id AND h.company_id = g.company_id
         AND h.source_doc_type = 'GRN' AND h.source_doc_no = g.grn_no AND h.source_doc_date = g.grn_date
        JOIN rid_finance_lines l
          ON l.client_id = h.client_id AND l.company_id = h.company_id
         AND l.location_id = h.location_id AND l.trans_no = h.trans_no
         AND l.source_line_type = 'ACCRUAL' AND l.is_deleted = false
        WHERE g.client_id = p_client_id AND g.company_id = p_company_id
          AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
          AND g.is_deleted = false
    LOOP
        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_grn_line.account_id, 'trans_nature', 'DR',
            'trans_amount', v_grn_line.trans_amount, 'trans_currency', v_grn_line.trans_currency,
            'base_amount', v_grn_line.base_amount, 'base_rate', v_grn_line.base_rate,
            'local_amount', v_grn_line.local_amount, 'local_rate', v_grn_line.local_rate,
            'party_amount', v_grn_line.party_amount, 'party_currency', v_grn_line.party_currency, 'party_rate', v_grn_line.party_rate,
            'source_line_type', 'ACCRUAL_CLEARING'
        ));
        v_dr_total := v_dr_total + v_grn_line.base_amount;
    END LOOP;

    -- 5. DR Input VAT — apportion the REAL lump-sum tax_amount across the
    --    linked GRNs' own lines by each line's share of the ESTIMATED tax
    --    that was never posted (rid_grn_lines.tax_amount), then within each
    --    line across its tax_group's member taxes by rate weight — same
    --    weighting fn_approve_grn used before VAT deferral (049), now
    --    applied to the real figure instead of the estimate.
    --
    -- Anchor product for the Exchange Gain/Loss resolution below — decoupled
    -- from the tax-only query beneath it (not filtered to taxed lines), so a
    -- bill whose GRN lines are entirely VAT-exempt still has an anchor.
    SELECT gl.product_id INTO v_anchor_product_id
    FROM rih_grn_headers g
    JOIN rid_grn_lines gl
      ON gl.client_id = g.client_id AND gl.company_id = g.company_id
     AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
     AND gl.is_deleted = false
    WHERE g.client_id = p_client_id AND g.company_id = p_company_id
      AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
      AND g.is_deleted = false
    LIMIT 1;

    SELECT coalesce(sum(gl.tax_amount), 0) INTO v_total_est_tax
    FROM rih_grn_headers g
    JOIN rid_grn_lines gl
      ON gl.client_id = g.client_id AND gl.company_id = g.company_id
     AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
     AND gl.is_deleted = false AND gl.tax_group_id IS NOT NULL AND gl.tax_amount <> 0
    WHERE g.client_id = p_client_id AND g.company_id = p_company_id
      AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
      AND g.is_deleted = false;

    IF v_header.tax_amount <> 0 THEN
        IF v_total_est_tax = 0 THEN
            RAISE EXCEPTION 'NO_TAXABLE_GRN_LINES'
                USING DETAIL = 'None of the linked GRN lines had a tax group / estimated tax to apportion the real VAT against.';
        END IF;

        FOR v_grn_line IN
            SELECT gl.tax_group_id, gl.tax_amount AS est_tax
            FROM rih_grn_headers g
            JOIN rid_grn_lines gl
              ON gl.client_id = g.client_id AND gl.company_id = g.company_id
             AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
             AND gl.is_deleted = false AND gl.tax_group_id IS NOT NULL AND gl.tax_amount <> 0
            WHERE g.client_id = p_client_id AND g.company_id = p_company_id
              AND g.billed_invoice_no = p_invoice_no AND g.billed_invoice_date = p_invoice_date
              AND g.is_deleted = false
        LOOP
            v_line_share := v_header.tax_amount * (v_grn_line.est_tax / v_total_est_tax);

            SELECT coalesce(sum(fn_get_active_tax_rate(tgm.tax_id, p_invoice_date)), 0) INTO v_rate_sum
            FROM rim_tax_group_members tgm
            WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
              AND tgm.tax_group_id = v_grn_line.tax_group_id;

            IF v_rate_sum > 0 THEN
                FOR v_tax_row IN
                    SELECT tgm.tax_id, t.gl_input_account_id, t.tax_code, t.tax_name,
                           fn_get_active_tax_rate(tgm.tax_id, p_invoice_date) AS rate
                    FROM rim_tax_group_members tgm
                    JOIN rim_taxes t ON t.id = tgm.tax_id
                    WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                      AND tgm.tax_group_id = v_grn_line.tax_group_id
                LOOP
                    IF v_tax_row.gl_input_account_id IS NULL THEN
                        RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                            USING DETAIL = format('Tax [%s] %s has no Input GL account configured.',
                                v_tax_row.tax_code, v_tax_row.tax_name);
                    END IF;

                    -- Same account-currency shortcut as every other line in
                    -- this function / GRN's own posting — never a bare
                    -- trans-currency assumption.
                    SELECT c.currency_id INTO v_tax_account_ccy
                    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
                    WHERE a.id = v_tax_row.gl_input_account_id;
                    IF v_tax_account_ccy IS NULL OR v_tax_account_ccy = v_invoice_ccy THEN
                        v_tax_party_rate := 1; v_tax_party_ccy := v_invoice_ccy;
                    ELSIF v_tax_account_ccy = v_base_ccy THEN
                        v_tax_party_rate := v_header.rate_to_base; v_tax_party_ccy := v_base_ccy;
                    ELSIF v_tax_account_ccy = v_local_ccy THEN
                        v_tax_party_rate := v_header.rate_to_local; v_tax_party_ccy := v_local_ccy;
                    ELSE
                        v_tax_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_invoice_ccy, v_tax_account_ccy, p_invoice_date);
                        v_tax_party_ccy := v_tax_account_ccy;
                    END IF;

                    v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
                        'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'DR',
                        'trans_amount', v_line_share * v_tax_row.rate / v_rate_sum, 'trans_currency', v_invoice_ccy,
                        'base_amount', v_line_share * v_tax_row.rate / v_rate_sum * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_line_share * v_tax_row.rate / v_rate_sum * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line_share * v_tax_row.rate / v_rate_sum * v_tax_party_rate, 'party_currency', v_tax_party_ccy, 'party_rate', v_tax_party_rate,
                        'source_line_type', 'INPUT_VAT'
                    ));
                    v_dr_total := v_dr_total + (v_line_share * v_tax_row.rate / v_rate_sum * v_header.rate_to_base);
                END LOOP;
            END IF;
        END LOOP;
    END IF;

    -- 6. CR Supplier Account = real invoice total, at the BILL's own rate —
    --    tagged with the SUPPLIER's own paper invoice number/date so this
    --    rides the existing generic pending-bills mechanism.
    v_supplier_trans_amt := v_header.taxable_amount + v_header.tax_amount;
    SELECT c.currency_id INTO v_account_ccy
    FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
    WHERE a.id = v_header.supplier_id;
    IF v_account_ccy IS NULL OR v_account_ccy = v_invoice_ccy THEN
        v_party_rate := 1; v_party_ccy := v_invoice_ccy;
    ELSIF v_account_ccy = v_base_ccy THEN
        v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
    ELSIF v_account_ccy = v_local_ccy THEN
        v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
    ELSE
        v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_invoice_ccy, v_account_ccy, p_invoice_date);
        v_party_ccy := v_account_ccy;
    END IF;

    v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
        'account_id', v_header.supplier_id, 'trans_nature', 'CR',
        'trans_amount', v_supplier_trans_amt, 'trans_currency', v_invoice_ccy,
        'base_amount', v_supplier_trans_amt * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
        'local_amount', v_supplier_trans_amt * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
        'party_amount', v_supplier_trans_amt * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
        'inv_bill_no', v_header.supplier_invoice_no, 'inv_bill_date', v_header.supplier_invoice_date,
        'source_line_type', 'SUPPLIER'
    ));
    v_cr_total := v_supplier_trans_amt * v_header.rate_to_base;

    -- 7. DR/CR Exchange Gain/Loss — whatever the above doesn't balance to.
    --    Positive = loss (DR), negative = gain (CR). Anchored on any one
    --    linked GRN line's product — EXCHANGE_GAIN_LOSS_ACCOUNT is a
    --    document-level account, always configured at COMPANY granularity
    --    in practice, so the anchor choice is immaterial to the resolved
    --    account; fn_resolve_account_link's cache table just requires one.
    v_fx_diff := v_dr_total - v_cr_total;
    IF abs(v_fx_diff) > 0.0001 THEN
        v_fx_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_anchor_product_id, 'EXCHANGE_GAIN_LOSS_ACCOUNT');
        IF v_fx_account IS NULL THEN
            RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                USING DETAIL = 'No Exchange Gain/Loss Account configured.';
        END IF;

        v_voucher_lines := v_voucher_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_fx_account,
            'trans_nature', CASE WHEN v_fx_diff < 0 THEN 'DR' ELSE 'CR' END,
            'trans_amount', abs(v_fx_diff), 'trans_currency', v_base_ccy,
            'base_amount', abs(v_fx_diff), 'base_rate', 1,
            'local_amount', abs(v_fx_diff) * (v_header.rate_to_local / v_header.rate_to_base), 'local_rate', v_header.rate_to_local / v_header.rate_to_base,
            'party_amount', abs(v_fx_diff), 'party_currency', v_base_ccy, 'party_rate', 1,
            'source_line_type', 'EXCHANGE_DIFF'
        ));
    END IF;

    UPDATE rih_purchase_invoices SET exchange_diff_base = v_fx_diff WHERE id = v_header.id;

    -- 8. One fn_post_voucher call for the whole bill, not per GRN.
    SELECT * INTO v_voucher_result FROM fn_post_voucher(
        p_client_id, p_company_id, v_header.location_id, 'JV', p_invoice_date,
        v_voucher_lines, 'PURCHASE_INVOICE', p_invoice_no, p_invoice_date, p_approved_by
    );

    -- 9. Mark the bill approved, store GL traceability.
    UPDATE rih_purchase_invoices SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = v_voucher_result.trans_no,
        posted_voucher_date = v_voucher_result.trans_date,
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_purchase_invoice(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ── fn_get_grn_billing_defaults ───────────────────────────────────────────────
-- Entry-screen auto-calc: as the user checks GRNs, the screen shows a
-- suggested taxable_amount/tax_amount so the user just validates against
-- the supplier's paper invoice and only edits on a genuine mismatch. Reads
-- the exact same sources fn_approve_purchase_invoice itself sums (ACCRUAL
-- lines' trans_amount, rid_grn_lines' estimated tax_amount) so the
-- preview can never drift from what actually posts.
CREATE OR REPLACE FUNCTION fn_get_grn_billing_defaults(
    p_client_id  UUID,
    p_company_id UUID,
    p_grn_refs   JSONB   -- [{grn_no, grn_date}, ...]
)
RETURNS TABLE (taxable_amount NUMERIC, tax_amount NUMERIC)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        coalesce((
            SELECT sum(l.trans_amount)
            FROM jsonb_array_elements(p_grn_refs) AS ref
            JOIN rih_grn_headers g
              ON g.client_id = p_client_id AND g.company_id = p_company_id
             AND g.grn_no = ref.value->>'grn_no' AND g.grn_date = (ref.value->>'grn_date')::date
             AND g.is_deleted = false
            JOIN rih_finance_headers h
              ON h.client_id = g.client_id AND h.company_id = g.company_id
             AND h.source_doc_type = 'GRN' AND h.source_doc_no = g.grn_no AND h.source_doc_date = g.grn_date
            JOIN rid_finance_lines l
              ON l.client_id = h.client_id AND l.company_id = h.company_id
             AND l.location_id = h.location_id AND l.trans_no = h.trans_no
             AND l.source_line_type = 'ACCRUAL' AND l.is_deleted = false
        ), 0),
        coalesce((
            SELECT sum(gl.tax_amount)
            FROM jsonb_array_elements(p_grn_refs) AS ref
            JOIN rih_grn_headers g
              ON g.client_id = p_client_id AND g.company_id = p_company_id
             AND g.grn_no = ref.value->>'grn_no' AND g.grn_date = (ref.value->>'grn_date')::date
             AND g.is_deleted = false
            JOIN rid_grn_lines gl
              ON gl.client_id = g.client_id AND gl.company_id = g.company_id
             AND gl.grn_no = g.grn_no AND gl.grn_date = g.grn_date
             AND gl.is_deleted = false AND gl.tax_group_id IS NOT NULL
        ), 0);
END;
$$;

GRANT EXECUTE ON FUNCTION fn_get_grn_billing_defaults(UUID, UUID, JSONB) TO authenticated;


-- ── Fix PR-INV menu seed: this screen has a real DRAFT->APPROVED workflow
-- like every other transactional document (PO/GRN), not the single-step
-- shape the initial placeholder seed guessed at.
UPDATE ric_master_menus SET approve_allowed = true
WHERE feature_code = 'PR-INV' AND approve_allowed = false;
