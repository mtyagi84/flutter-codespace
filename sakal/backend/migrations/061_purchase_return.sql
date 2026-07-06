-- ============================================================
-- Migration 061: Purchase Return
-- ============================================================
-- Handles BOTH scenarios discussed live as one unified feature — "return"
-- and "reverse" are the same mechanism regardless of the human reason
-- (defective goods vs a data-entry mistake); the reason is just a label
-- for the audit trail (rih_purchase_return_headers.reason), never a
-- different code path.
--
-- Entry flow: pick a Supplier -> pick one or more of their APPROVED GRNs
-- -> all lines from those GRNs appear with GRN qty pre-filled as return
-- qty (user reduces/zeroes/deletes per line) -> any charges on those GRNs
-- populate as editable defaults -> system suggests a taxable_amount/
-- tax_amount (computed FRESH from the GRN lines' own rate/tax_group data,
-- never derived from a Bill's posted lump sums — this is what makes
-- mixed/multi-GRN-bill returns tractable at all, see below) -> user
-- confirms or overrides against the real debit note -> approve.
--
-- One return CAN mix GRNs of different billed status (discussed live) —
-- a GRN not yet billed only has a provisional Accrual to reverse; a
-- billed GRN has a REAL Supplier payable + Input VAT to reverse instead
-- (the Accrual for a billed GRN is already net-zero, cleared by the Bill —
-- untouched here). So one Approve can post up to two vouchers:
--   JV  — for the unbilled portion: DR Purchase Accrual / CR Stock,
--         tax-exclusive (matches how the GRN itself posted, tax deferred).
--   SDN — for the billed portion: DR Supplier / CR Stock / CR Input VAT /
--         DR-or-CR Purchase Returns (new contra account, plugs whatever the
--         user's confirmed Supplier Amount doesn't split evenly across
--         Stock+VAT — unlike Purchase Bill's Exchange plug, this one CAN
--         live in the SAME voucher/trans_currency as the rest of the SDN,
--         since a return-value adjustment is a genuine transaction-currency
--         event, not a pure base-currency FX artifact).
-- Both vouchers (when both exist) tag the same source_doc_type=
-- 'PURCHASE_RETURN'/source_doc_no=return_no, so the entry screen's Posted
-- Journal Entries section (same pattern as GRN/Purchase Bill) picks up
-- both with no extra plumbing.
--
-- Stock: always posts an outward movement (fn_post_stock_movement,
-- trans_type='PURCHASE_RETURN') per return line, now subject to the
-- negative-stock check added in migration 060 (item AND location must
-- both allow it, else the return is blocked for that line).
--
-- PO: qty_received on any referenced PO line ALWAYS decreases by the
-- returned qty (accurate net-received reporting) — only the PO's STATUS
-- rollback (CLOSED -> PARTIALLY_RECEIVED, making it eligible for further
-- GRNs again) depends on the caller's p_reopen_po flag, applied uniformly
-- across every PO touched by this return (not per-PO granularity in v1).
--
-- One supplier per return (matches PO/GRN/Bill's existing convention).
--
-- Objects:
--   rih_purchase_return_headers, rid_purchase_return_lines,
--   rid_purchase_return_charge_lines
--   v_grn_return_links   -> plain view, mirrors v_grn_po_links
--   fn_save_purchase_return(...)     -> DRAFT-only
--   fn_approve_purchase_return(...)  -> the orchestration described above
-- ============================================================

-- ── Seed 'PRET' voucher type (needed by fn_next_trans_no, numbers return_no
--    itself — NOT the ledger voucher, same separation as GRN/grn_no and
--    Purchase Invoice/invoice_no) ───────────────────────────────────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('PRET', 'Purchase Return', 'PURCHASE', NULL, 'YEARLY', 'PRET/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;

-- ── New account-link type: Purchase Returns contra account ──────────────────
INSERT INTO rim_account_link_types (link_key, link_name, sort_order) VALUES
    ('PURCHASE_RETURNS_ACCOUNT', 'Purchase Returns Account', 150)
ON CONFLICT (link_key) DO NOTHING;

-- ── rih_purchase_return_headers ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS rih_purchase_return_headers (
    id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id           UUID          NOT NULL REFERENCES ric_clients(id),
    company_id          UUID          NOT NULL REFERENCES ric_companies(id),
    location_id         UUID          NOT NULL REFERENCES ric_locations(id),
    return_no           TEXT          NOT NULL,
    return_date         DATE          NOT NULL,
    supplier_id         UUID          NOT NULL REFERENCES rim_accounts(id),
    return_currency_id  UUID          REFERENCES rim_currencies(id),
    rate_to_base        NUMERIC(18,8) NOT NULL DEFAULT 1,
    rate_to_local       NUMERIC(18,8) NOT NULL DEFAULT 1,
    -- User-confirmed aggregate totals — default = system-suggested (computed
    -- fresh from the selected GRN lines' own rate/tax_group data), editable
    -- against the real supplier debit note. tax_amount only ever applies to
    -- the billed portion of this return (unbilled GRNs have no real VAT to
    -- reverse) — see fn_approve_purchase_return's apportionment.
    taxable_amount      NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount          NUMERIC(18,4) NOT NULL DEFAULT 0,
    charges_amount      NUMERIC(18,4) NOT NULL DEFAULT 0,
    return_total        NUMERIC(18,4) NOT NULL DEFAULT 0,
    reason              TEXT,          -- free text: "Defective", "Wrong Item", "Data Entry Correction", ... — label only, never branches logic
    remarks             TEXT,
    status              TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
    approved_by         UUID          REFERENCES rim_users(id),
    approved_at         TIMESTAMPTZ,
    -- Primary GL reference — the SDN if this return touched any billed GRN,
    -- else the JV. Either or both vouchers are fully discoverable via
    -- source_doc_type/source_doc_no regardless (Posted Journal Entries UI
    -- queries by source doc, same as Purchase Bill's PUR+EXC pattern).
    posted_voucher_no   TEXT,
    posted_voucher_date DATE,
    is_active           BOOLEAN       NOT NULL DEFAULT true,
    is_deleted          BOOLEAN       NOT NULL DEFAULT false,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by          UUID          REFERENCES rim_users(id),
    updated_at          TIMESTAMPTZ,
    updated_by          UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, return_no, return_date)
);

CREATE INDEX IF NOT EXISTS idx_purchase_return_headers_supplier ON rih_purchase_return_headers (client_id, company_id, supplier_id);
CREATE INDEX IF NOT EXISTS idx_purchase_return_headers_status   ON rih_purchase_return_headers (client_id, company_id, status);

DROP TRIGGER IF EXISTS trg_rih_purchase_return_headers_updated_at ON rih_purchase_return_headers;
CREATE TRIGGER trg_rih_purchase_return_headers_updated_at
    BEFORE UPDATE ON rih_purchase_return_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_purchase_return_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_purchase_return_headers" ON rih_purchase_return_headers;
CREATE POLICY "auth_rw_purchase_return_headers" ON rih_purchase_return_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_purchase_return_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_purchase_return_headers TO authenticated;

-- ── rid_purchase_return_lines ─────────────────────────────────────────────────
-- One row per GRN line being returned against (base_qty here = the RETURN
-- qty, always <= that GRN line's own remaining returnable qty — enforced at
-- Approve time in fn_approve_purchase_return, not at Save, matching the
-- "DRAFT saves don't need to validate as strictly" convention used
-- elsewhere). rate/tax_group_id are inherited read-only from the source GRN
-- line; gross_amount/tax_amount/final_amount here are the per-line SUGGESTED
-- figures (used only as apportionment weights) — the user-confirmed real
-- totals live on the header.
CREATE TABLE IF NOT EXISTS rid_purchase_return_lines (
    id                     UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id              UUID          NOT NULL,
    company_id             UUID          NOT NULL,
    return_no              TEXT          NOT NULL,
    return_date            DATE          NOT NULL,
    serial_no              INTEGER       NOT NULL,
    source_grn_no          TEXT          NOT NULL,
    source_grn_date        DATE          NOT NULL,
    source_grn_line_serial INTEGER       NOT NULL,
    product_id             UUID          NOT NULL REFERENCES rim_products(id),
    uom_id                 UUID,
    uom_conversion_factor  NUMERIC(18,6) NOT NULL DEFAULT 1,
    qty_pack               NUMERIC(18,4) NOT NULL DEFAULT 0,
    qty_loose              NUMERIC(18,4) NOT NULL DEFAULT 0,
    base_qty               NUMERIC(18,4) NOT NULL DEFAULT 0,   -- the RETURN quantity
    rate                   NUMERIC(18,4) NOT NULL DEFAULT 0,   -- inherited from the GRN line
    tax_group_id           UUID          REFERENCES rim_tax_groups(id),
    gross_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,   -- suggested, apportionment weight only
    tax_amount             NUMERIC(18,4) NOT NULL DEFAULT 0,   -- suggested, apportionment weight only
    final_amount           NUMERIC(18,4) NOT NULL DEFAULT 0,
    is_deleted             BOOLEAN       NOT NULL DEFAULT false,
    created_at             TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by             UUID          REFERENCES rim_users(id),
    updated_at             TIMESTAMPTZ,
    updated_by             UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, return_no, return_date, serial_no),
    FOREIGN KEY (client_id, company_id, return_no, return_date)
        REFERENCES rih_purchase_return_headers (client_id, company_id, return_no, return_date)
);

CREATE INDEX IF NOT EXISTS idx_purchase_return_lines_source_grn
    ON rid_purchase_return_lines (client_id, company_id, source_grn_no, source_grn_date, source_grn_line_serial);
CREATE INDEX IF NOT EXISTS idx_purchase_return_lines_product
    ON rid_purchase_return_lines (product_id);

ALTER TABLE rid_purchase_return_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_purchase_return_lines" ON rid_purchase_return_lines;
CREATE POLICY "auth_rw_purchase_return_lines" ON rid_purchase_return_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_purchase_return_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_purchase_return_lines TO authenticated;

-- ── rid_purchase_return_charge_lines ──────────────────────────────────────────
-- Mirrors rid_grn_charge_lines' shape. Pre-populated as editable defaults
-- from the linked GRN(s)' own charge lines (source_grn_no/date traces which
-- GRN a charge came from) — same "pull forward as a default, not gospel"
-- precedent GRN itself uses for PO charges.
CREATE TABLE IF NOT EXISTS rid_purchase_return_charge_lines (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL,
    company_id        UUID          NOT NULL,
    return_no         TEXT          NOT NULL,
    return_date       DATE          NOT NULL,
    serial_no         INTEGER       NOT NULL,
    charge_id         UUID          NOT NULL REFERENCES rim_additional_charges(id),
    charge_name       TEXT          NOT NULL,
    is_taxable        BOOLEAN       NOT NULL DEFAULT false,
    tax_id            UUID          REFERENCES rim_taxes(id),
    nature            TEXT          NOT NULL DEFAULT 'ADD' CHECK (nature IN ('ADD','DEDUCT')),
    gl_account_id     UUID          REFERENCES rim_accounts(id),
    amount            NUMERIC(18,4) NOT NULL DEFAULT 0,
    tax_amount        NUMERIC(18,4) NOT NULL DEFAULT 0,
    source_grn_no     TEXT,
    source_grn_date   DATE,
    is_deleted        BOOLEAN       NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    updated_at        TIMESTAMPTZ,
    updated_by        UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, return_no, return_date, serial_no),
    FOREIGN KEY (client_id, company_id, return_no, return_date)
        REFERENCES rih_purchase_return_headers (client_id, company_id, return_no, return_date)
);

ALTER TABLE rid_purchase_return_charge_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_purchase_return_charge_lines" ON rid_purchase_return_charge_lines;
CREATE POLICY "auth_rw_purchase_return_charge_lines" ON rid_purchase_return_charge_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_purchase_return_charge_lines FROM anon;
GRANT SELECT, INSERT, UPDATE ON rid_purchase_return_charge_lines TO authenticated;

-- ── v_grn_return_links ────────────────────────────────────────────────────────
-- "Which GRNs has this return touched" — plain view off rid_purchase_return_
-- lines (already indexed on source_grn_*), mirrors v_grn_po_links exactly.
CREATE OR REPLACE VIEW v_grn_return_links AS
SELECT DISTINCT client_id, company_id, return_no, return_date, source_grn_no, source_grn_date
FROM rid_purchase_return_lines
WHERE is_deleted = false;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_save_purchase_return — DRAFT-only, mirrors fn_save_grn/fn_save_purchase_invoice
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_save_purchase_return(
    p_header    JSONB,
    p_lines     JSONB,   -- [{serial_no, source_grn_no, source_grn_date, source_grn_line_serial, product_id, uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate, tax_group_id, gross_amount, tax_amount, final_amount}, ...]
    p_charges   JSONB,   -- [{serial_no, charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id, amount, tax_amount, source_grn_no, source_grn_date}, ...]
    p_user_id   UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id     UUID;
    v_company_id    UUID;
    v_location_id   UUID;
    v_supplier_id   UUID;
    v_return_no     TEXT;
    v_return_date   DATE;
    v_old_status    TEXT;
    v_is_new        BOOLEAN;
    v_line          JSONB;
    v_charge        JSONB;
    v_grn_ref       RECORD;
    v_grn           rih_grn_headers%ROWTYPE;
    v_charges_total NUMERIC := 0;
BEGIN
    v_client_id   := (p_header->>'client_id')::uuid;
    v_company_id  := (p_header->>'company_id')::uuid;
    v_location_id := (p_header->>'location_id')::uuid;
    v_supplier_id := (p_header->>'supplier_id')::uuid;
    v_return_no   := nullif(trim(p_header->>'return_no'), '');
    v_return_date := (p_header->>'return_date')::date;
    v_is_new      := v_return_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to raise a Purchase Return.';
    END IF;

    IF v_is_new THEN
        v_return_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'PRET');
    ELSE
        SELECT status INTO v_old_status
        FROM rih_purchase_return_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND is_deleted = false
        FOR UPDATE;

        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Purchase Return % is % and cannot be edited.', v_return_no, v_old_status;
        END IF;

        DELETE FROM rid_purchase_return_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
        DELETE FROM rid_purchase_return_charge_lines
        WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;
    END IF;

    -- Validate every referenced GRN: same supplier, APPROVED. One row per
    -- statement in a fixed sort order (deadlock-avoidance rule from 036/038).
    FOR v_grn_ref IN
        SELECT DISTINCT value->>'source_grn_no' AS grn_no, value->>'source_grn_date' AS grn_date
        FROM jsonb_array_elements(p_lines)
        ORDER BY 1, 2
    LOOP
        SELECT * INTO v_grn FROM rih_grn_headers
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND grn_no = v_grn_ref.grn_no AND grn_date = v_grn_ref.grn_date::date
          AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'GRN % not found.', v_grn_ref.grn_no;
        END IF;
        IF v_grn.status != 'APPROVED' THEN
            RAISE EXCEPTION 'GRN % is % — only APPROVED GRNs can be returned against.', v_grn.grn_no, v_grn.status;
        END IF;
        IF v_grn.supplier_id != v_supplier_id THEN
            RAISE EXCEPTION 'GRN % does not belong to the selected supplier.', v_grn.grn_no;
        END IF;
    END LOOP;

    IF v_is_new THEN
        INSERT INTO rih_purchase_return_headers (
            client_id, company_id, location_id, return_no, return_date, supplier_id,
            return_currency_id, rate_to_base, rate_to_local,
            taxable_amount, tax_amount, charges_amount, return_total,
            reason, remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_return_no, v_return_date, v_supplier_id,
            (p_header->>'return_currency_id')::uuid,
            coalesce((p_header->>'rate_to_base')::numeric, 1),
            coalesce((p_header->>'rate_to_local')::numeric, 1),
            coalesce((p_header->>'taxable_amount')::numeric, 0),
            coalesce((p_header->>'tax_amount')::numeric, 0),
            coalesce((p_header->>'charges_amount')::numeric, 0),
            coalesce((p_header->>'return_total')::numeric, 0),
            nullif(p_header->>'reason', ''), nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_purchase_return_headers SET
            location_id          = v_location_id,
            return_date          = v_return_date,
            supplier_id          = v_supplier_id,
            return_currency_id  = (p_header->>'return_currency_id')::uuid,
            rate_to_base        = coalesce((p_header->>'rate_to_base')::numeric, 1),
            rate_to_local       = coalesce((p_header->>'rate_to_local')::numeric, 1),
            taxable_amount      = coalesce((p_header->>'taxable_amount')::numeric, 0),
            tax_amount          = coalesce((p_header->>'tax_amount')::numeric, 0),
            charges_amount      = coalesce((p_header->>'charges_amount')::numeric, 0),
            return_total        = coalesce((p_header->>'return_total')::numeric, 0),
            reason              = nullif(p_header->>'reason', ''),
            remarks             = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND return_no = v_return_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_purchase_return_lines (
            client_id, company_id, return_no, return_date, serial_no,
            source_grn_no, source_grn_date, source_grn_line_serial, product_id,
            uom_id, uom_conversion_factor, qty_pack, qty_loose, base_qty, rate,
            tax_group_id, gross_amount, tax_amount, final_amount,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_line->>'serial_no')::integer,
            v_line->>'source_grn_no', (v_line->>'source_grn_date')::date, (v_line->>'source_grn_line_serial')::integer,
            (v_line->>'product_id')::uuid,
            nullif(v_line->>'uom_id', '')::uuid, coalesce((v_line->>'uom_conversion_factor')::numeric, 1),
            coalesce((v_line->>'qty_pack')::numeric, 0), coalesce((v_line->>'qty_loose')::numeric, 0),
            coalesce((v_line->>'base_qty')::numeric, 0), coalesce((v_line->>'rate')::numeric, 0),
            nullif(v_line->>'tax_group_id', '')::uuid,
            coalesce((v_line->>'gross_amount')::numeric, 0), coalesce((v_line->>'tax_amount')::numeric, 0),
            coalesce((v_line->>'final_amount')::numeric, 0),
            p_user_id, p_user_id
        );
    END LOOP;

    FOR v_charge IN SELECT * FROM jsonb_array_elements(p_charges)
    LOOP
        INSERT INTO rid_purchase_return_charge_lines (
            client_id, company_id, return_no, return_date, serial_no,
            charge_id, charge_name, is_taxable, tax_id, nature, gl_account_id,
            amount, tax_amount, source_grn_no, source_grn_date,
            created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_return_no, v_return_date, (v_charge->>'serial_no')::integer,
            (v_charge->>'charge_id')::uuid, v_charge->>'charge_name',
            coalesce((v_charge->>'is_taxable')::boolean, false), nullif(v_charge->>'tax_id', '')::uuid,
            coalesce(v_charge->>'nature', 'ADD'), nullif(v_charge->>'gl_account_id', '')::uuid,
            coalesce((v_charge->>'amount')::numeric, 0), coalesce((v_charge->>'tax_amount')::numeric, 0),
            nullif(v_charge->>'source_grn_no', ''), nullif(v_charge->>'source_grn_date', '')::date,
            p_user_id, p_user_id
        );
        v_charges_total := v_charges_total + coalesce((v_charge->>'amount')::numeric, 0);
    END LOOP;

    UPDATE rih_purchase_return_headers SET charges_amount = v_charges_total
    WHERE client_id = v_client_id AND company_id = v_company_id AND return_no = v_return_no;

    RETURN v_return_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_purchase_return(JSONB, JSONB, JSONB, UUID) TO authenticated;


-- ═══════════════════════════════════════════════════════════════════════════
-- fn_approve_purchase_return
-- ═══════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION fn_approve_purchase_return(
    p_client_id   UUID,
    p_company_id  UUID,
    p_return_no   TEXT,
    p_return_date DATE,
    p_reopen_po   BOOLEAN,
    p_approved_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header            rih_purchase_return_headers%ROWTYPE;
    v_return_ccy        TEXT;
    v_base_ccy          TEXT;
    v_local_ccy         TEXT;
    v_grn_key           RECORD;
    v_grn               rih_grn_headers%ROWTYPE;
    v_line              RECORD;
    v_tax_row           RECORD;
    v_po_key            RECORD;
    v_total_est_taxable NUMERIC := 0;
    v_total_est_tax_billed NUMERIC := 0;
    v_grn_taxable       NUMERIC;
    v_grn_tax           NUMERIC;
    v_line_actual_taxable NUMERIC;
    v_line_actual_tax   NUMERIC;
    v_account_ccy       TEXT;
    v_party_rate        NUMERIC;
    v_party_ccy         TEXT;
    v_stock_account     UUID;
    v_accrual_account   UUID;
    v_returns_account    UUID;
    v_anchor_product_id UUID;
    v_rate_sum          NUMERIC;
    v_jv_lines          JSONB := '[]'::jsonb;
    v_sdn_lines         JSONB := '[]'::jsonb;
    v_jv_trans_no       TEXT;
    v_jv_trans_date     DATE;
    v_sdn_trans_no      TEXT;
    v_sdn_trans_date    DATE;
    v_supplier_dr_total NUMERIC := 0;
    v_sdn_cr_total      NUMERIC := 0;
    v_plug              NUMERIC;
    v_po_total_ordered  NUMERIC;
    v_po_total_received NUMERIC;
    v_po_any_short      BOOLEAN;
BEGIN
    -- 1. Lock header, validate status
    SELECT * INTO v_header FROM rih_purchase_return_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND return_no = p_return_no AND return_date = p_return_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Purchase Return % dated % not found', p_return_no, p_return_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Purchase Return % is % and cannot be approved again', p_return_no, v_header.status;
    END IF;

    -- 2. Period + backdate checks
    PERFORM fn_check_period_open(p_company_id, p_return_date);
    PERFORM fn_check_backdate_allowed(p_client_id, p_company_id, 'PURCHASE_RETURN', p_return_date);

    -- 3. Lock every referenced GRN, one row per statement in a fixed sort
    --    order (same rule as fn_save_purchase_return / fn_approve_grn).
    FOR v_grn_key IN
        SELECT DISTINCT source_grn_no, source_grn_date FROM rid_purchase_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY source_grn_no, source_grn_date
    LOOP
        PERFORM 1 FROM rih_grn_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = v_grn_key.source_grn_no AND grn_date = v_grn_key.source_grn_date
        FOR UPDATE;
    END LOOP;

    SELECT currency_id INTO v_return_ccy FROM rim_currencies WHERE id = v_header.return_currency_id;
    SELECT base_currency, local_currency INTO v_base_ccy, v_local_ccy FROM ric_companies WHERE id = p_company_id;

    -- 4. Suggestion totals across ALL lines — used purely as apportionment
    --    weights for the header's user-confirmed taxable_amount/tax_amount.
    --    Tax weight only accumulates from lines whose GRN is already billed
    --    (an unbilled GRN's line-level tax_amount is just the still-deferred
    --    GR/IR estimate — no real VAT exists there to reverse).
    SELECT coalesce(sum(l.gross_amount), 0) INTO v_total_est_taxable
    FROM rid_purchase_return_lines l
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false;

    IF v_total_est_taxable = 0 THEN
        RAISE EXCEPTION 'NO_RETURN_LINES'
            USING DETAIL = 'This return has no lines with a non-zero value to apportion against.';
    END IF;

    -- Anchor product for the Purchase Returns contra account resolution
    -- below — fn_resolve_account_link's own cache keys on product_id, so a
    -- NULL product_id (even though COMPANY-level resolution doesn't
    -- logically need one) would always cache-miss. Same precedent as
    -- Purchase Bill's Exchange Gain/Loss anchor (059).
    SELECT product_id INTO v_anchor_product_id
    FROM rid_purchase_return_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
    LIMIT 1;

    SELECT coalesce(sum(l.tax_amount), 0) INTO v_total_est_tax_billed
    FROM rid_purchase_return_lines l
    JOIN rih_grn_headers g
      ON g.client_id = l.client_id AND g.company_id = l.company_id
     AND g.grn_no = l.source_grn_no AND g.grn_date = l.source_grn_date
    WHERE l.client_id = p_client_id AND l.company_id = p_company_id
      AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false
      AND g.billed_invoice_no IS NOT NULL;

    IF v_header.tax_amount <> 0 AND v_total_est_tax_billed = 0 THEN
        RAISE EXCEPTION 'NO_BILLED_LINES_FOR_TAX'
            USING DETAIL = 'A non-zero VAT amount was entered, but none of this return''s lines belong to an already-billed GRN.';
    END IF;

    -- 5. Walk each referenced GRN — post stock reversal for every line
    --    (always), then branch the financial reversal by billed status.
    FOR v_grn_key IN
        SELECT DISTINCT source_grn_no, source_grn_date FROM rid_purchase_return_lines
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND return_no = p_return_no AND return_date = p_return_date AND is_deleted = false
        ORDER BY source_grn_no, source_grn_date
    LOOP
        SELECT * INTO v_grn FROM rih_grn_headers
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND grn_no = v_grn_key.source_grn_no AND grn_date = v_grn_key.source_grn_date;

        v_grn_taxable := 0;
        v_grn_tax := 0;

        FOR v_line IN
            SELECT l.*, gl.source_po_order_no, gl.source_po_order_date, gl.source_po_line_serial,
                   gl.base_qty AS grn_line_base_qty
            FROM rid_purchase_return_lines l
            JOIN rid_grn_lines gl
              ON gl.client_id = l.client_id AND gl.company_id = l.company_id
             AND gl.grn_no = l.source_grn_no AND gl.grn_date = l.source_grn_date
             AND gl.serial_no = l.source_grn_line_serial
            WHERE l.client_id = p_client_id AND l.company_id = p_company_id
              AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false
              AND l.source_grn_no = v_grn_key.source_grn_no AND l.source_grn_date = v_grn_key.source_grn_date
            ORDER BY l.product_id
        LOOP
            -- Cap the returned qty against what's left returnable on this
            -- GRN line — SUM of every OTHER already-APPROVED return against
            -- the same GRN line (this return itself is still DRAFT during
            -- this check, so it's naturally excluded) must not, combined
            -- with this line's own qty, exceed what the GRN line originally
            -- received. A line can be partially returned across several
            -- separate Purchase Return documents over time.
            DECLARE
                v_already_returned NUMERIC;
            BEGIN
                SELECT coalesce(sum(pl.base_qty), 0) INTO v_already_returned
                FROM rid_purchase_return_lines pl
                JOIN rih_purchase_return_headers ph
                  ON ph.client_id = pl.client_id AND ph.company_id = pl.company_id
                 AND ph.return_no = pl.return_no AND ph.return_date = pl.return_date
                WHERE pl.client_id = p_client_id AND pl.company_id = p_company_id
                  AND pl.source_grn_no = v_line.source_grn_no AND pl.source_grn_date = v_line.source_grn_date
                  AND pl.source_grn_line_serial = v_line.source_grn_line_serial
                  AND pl.is_deleted = false AND ph.status = 'APPROVED';

                IF v_already_returned + v_line.base_qty > v_line.grn_line_base_qty THEN
                    RAISE EXCEPTION 'RETURN_QTY_EXCEEDS_RECEIVED'
                        USING DETAIL = format(
                            'GRN %s line %s: already returned %s of %s received, this return adds %s more.',
                            v_line.source_grn_no, v_line.source_grn_line_serial,
                            v_already_returned, v_line.grn_line_base_qty, v_line.base_qty);
                END IF;
            END;

            -- Stock: always reverses, regardless of billed status. No
            -- unit_cost needed for an outward movement — fn_post_stock_
            -- movement snapshots the CURRENT average cost itself.
            PERFORM fn_post_stock_movement(
                p_client_id, p_company_id, v_header.location_id, v_line.product_id,
                p_return_date, 'PURCHASE_RETURN', -v_line.base_qty,
                NULL, NULL, NULL, NULL, NULL,
                'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
            );

            -- Roll qty_received BACK on the referenced PO line, if any —
            -- always, regardless of p_reopen_po (that flag only gates the
            -- PO's own status recompute below, not this figure).
            IF v_line.source_po_order_no IS NOT NULL THEN
                UPDATE rid_purchase_order_lines SET
                    qty_received = qty_received - v_line.base_qty,
                    updated_at = now(), updated_by = p_approved_by
                WHERE client_id = p_client_id AND company_id = p_company_id
                  AND order_no = v_line.source_po_order_no AND order_date = v_line.source_po_order_date
                  AND serial_no = v_line.source_po_line_serial;
            END IF;

            v_line_actual_taxable := v_header.taxable_amount * (v_line.gross_amount / v_total_est_taxable);
            v_grn_taxable := v_grn_taxable + v_line_actual_taxable;

            IF v_grn.billed_invoice_no IS NULL THEN
                -- Unbilled: reverse the still-provisional Accrual, tax-
                -- exclusive — mirrors exactly how the GRN itself posted it.
                v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
                v_accrual_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'PURCHASE_ACCRUAL_ACCOUNT');
                IF v_stock_account IS NULL OR v_accrual_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('No Stock/Purchase Accrual Account resolved for product %s.',
                            (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
                END IF;

                v_jv_lines := v_jv_lines || jsonb_build_array(
                    jsonb_build_object(
                        'account_id', v_accrual_account, 'trans_nature', 'DR',
                        'trans_amount', v_line_actual_taxable, 'trans_currency', v_return_ccy,
                        'base_amount', v_line_actual_taxable * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_line_actual_taxable * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line_actual_taxable, 'party_currency', v_return_ccy, 'party_rate', 1,
                        'source_line_type', 'ACCRUAL_REVERSAL'
                    ),
                    jsonb_build_object(
                        'account_id', v_stock_account, 'trans_nature', 'CR',
                        'trans_amount', v_line_actual_taxable, 'trans_currency', v_return_ccy,
                        'base_amount', v_line_actual_taxable * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                        'local_amount', v_line_actual_taxable * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                        'party_amount', v_line_actual_taxable, 'party_currency', v_return_ccy, 'party_rate', 1,
                        'source_line_type', 'STOCK_REVERSAL'
                    )
                );
            ELSE
                -- Billed: Accrual already net-zero (cleared by the Bill) —
                -- untouched. Reverse Stock + Input VAT instead; Supplier is
                -- posted once, in aggregate, after this loop.
                v_stock_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_line.product_id, 'STOCK_ACCOUNT');
                IF v_stock_account IS NULL THEN
                    RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                        USING DETAIL = format('No Stock Account resolved for product %s.',
                            (SELECT '[' || product_code || '] ' || product_name FROM rim_products WHERE id = v_line.product_id));
                END IF;

                v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
                    'account_id', v_stock_account, 'trans_nature', 'CR',
                    'trans_amount', v_line_actual_taxable, 'trans_currency', v_return_ccy,
                    'base_amount', v_line_actual_taxable * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                    'local_amount', v_line_actual_taxable * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                    'party_amount', v_line_actual_taxable, 'party_currency', v_return_ccy, 'party_rate', 1,
                    'source_line_type', 'STOCK_REVERSAL'
                ));
                v_sdn_cr_total := v_sdn_cr_total + (v_line_actual_taxable * v_header.rate_to_base);

                IF v_total_est_tax_billed > 0 AND v_line.tax_group_id IS NOT NULL AND v_line.tax_amount <> 0 THEN
                    v_line_actual_tax := v_header.tax_amount * (v_line.tax_amount / v_total_est_tax_billed);
                    v_grn_tax := v_grn_tax + v_line_actual_tax;

                    SELECT coalesce(sum(fn_get_active_tax_rate(tgm.tax_id, p_return_date)), 0) INTO v_rate_sum
                    FROM rim_tax_group_members tgm
                    WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                      AND tgm.tax_group_id = v_line.tax_group_id;

                    IF v_rate_sum > 0 THEN
                        FOR v_tax_row IN
                            SELECT tgm.tax_id, t.gl_input_account_id, t.tax_code, t.tax_name,
                                   fn_get_active_tax_rate(tgm.tax_id, p_return_date) AS rate
                            FROM rim_tax_group_members tgm
                            JOIN rim_taxes t ON t.id = tgm.tax_id
                            WHERE tgm.client_id = p_client_id AND tgm.company_id = p_company_id
                              AND tgm.tax_group_id = v_line.tax_group_id
                        LOOP
                            IF v_tax_row.gl_input_account_id IS NULL THEN
                                RAISE EXCEPTION 'TAX_ACCOUNT_NOT_CONFIGURED'
                                    USING DETAIL = format('Tax [%s] %s has no Input GL account configured.',
                                        v_tax_row.tax_code, v_tax_row.tax_name);
                            END IF;

                            v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
                                'account_id', v_tax_row.gl_input_account_id, 'trans_nature', 'CR',
                                'trans_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum, 'trans_currency', v_return_ccy,
                                'base_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
                                'local_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
                                'party_amount', v_line_actual_tax * v_tax_row.rate / v_rate_sum, 'party_currency', v_return_ccy, 'party_rate', 1,
                                'source_line_type', 'INPUT_VAT_REVERSAL'
                            ));
                            v_sdn_cr_total := v_sdn_cr_total + (v_line_actual_tax * v_tax_row.rate / v_rate_sum * v_header.rate_to_base);
                        END LOOP;
                    END IF;
                END IF;
            END IF;
        END LOOP;

        IF v_grn.billed_invoice_no IS NOT NULL THEN
            v_supplier_dr_total := v_supplier_dr_total + v_grn_taxable + v_grn_tax;
        END IF;
    END LOOP;

    -- 6. One aggregate Supplier DR line for the whole SDN (one supplier per
    --    return, by construction) — deliberately NOT tagged with inv_bill_no
    --    (a plain on-account debit note, not tied into bill-settlement
    --    tracking — a known v1 simplification).
    IF v_supplier_dr_total > 0 THEN
        SELECT c.currency_id INTO v_account_ccy
        FROM rim_accounts a LEFT JOIN rim_currencies c ON c.id = a.account_currency_id
        WHERE a.id = v_header.supplier_id;
        IF v_account_ccy IS NULL OR v_account_ccy = v_return_ccy THEN
            v_party_rate := 1; v_party_ccy := v_return_ccy;
        ELSIF v_account_ccy = v_base_ccy THEN
            v_party_rate := v_header.rate_to_base; v_party_ccy := v_base_ccy;
        ELSIF v_account_ccy = v_local_ccy THEN
            v_party_rate := v_header.rate_to_local; v_party_ccy := v_local_ccy;
        ELSE
            v_party_rate := fn_get_exchange_rate(p_company_id, v_header.location_id, v_return_ccy, v_account_ccy, p_return_date);
            v_party_ccy := v_account_ccy;
        END IF;

        v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
            'account_id', v_header.supplier_id, 'trans_nature', 'DR',
            'trans_amount', v_supplier_dr_total, 'trans_currency', v_return_ccy,
            'base_amount', v_supplier_dr_total * v_header.rate_to_base, 'base_rate', v_header.rate_to_base,
            'local_amount', v_supplier_dr_total * v_header.rate_to_local, 'local_rate', v_header.rate_to_local,
            'party_amount', v_supplier_dr_total * v_party_rate, 'party_currency', v_party_ccy, 'party_rate', v_party_rate,
            'source_line_type', 'SUPPLIER_REVERSAL'
        ));

        -- Plug: whatever the confirmed Supplier amount doesn't split evenly
        -- across Stock+VAT — e.g. the user typed Supplier/VAT figures that
        -- don't reconcile to the penny, or a negotiated settlement differs
        -- from the pure return value. Unlike Purchase Bill's Exchange plug,
        -- this one IS a genuine transaction-currency event (a real
        -- return-value adjustment, not a pure base-currency FX artifact),
        -- so it lives in this SAME voucher/currency, no separate voucher
        -- needed.
        v_plug := (v_supplier_dr_total * v_header.rate_to_base) - v_sdn_cr_total;
        IF abs(v_plug) > 0.0001 THEN
            v_returns_account := fn_resolve_account_link(p_client_id, p_company_id, v_header.location_id, v_anchor_product_id, 'PURCHASE_RETURNS_ACCOUNT');
            IF v_returns_account IS NULL THEN
                RAISE EXCEPTION 'ACCOUNT_LINK_NOT_CONFIGURED'
                    USING DETAIL = 'No Purchase Returns Account configured.';
            END IF;

            v_sdn_lines := v_sdn_lines || jsonb_build_array(jsonb_build_object(
                'account_id', v_returns_account,
                'trans_nature', CASE WHEN v_plug > 0 THEN 'CR' ELSE 'DR' END,
                'trans_amount', abs(v_plug) / v_header.rate_to_base, 'trans_currency', v_return_ccy,
                'base_amount', abs(v_plug), 'base_rate', v_header.rate_to_base,
                'local_amount', abs(v_plug) * (v_header.rate_to_local / v_header.rate_to_base), 'local_rate', v_header.rate_to_local,
                'party_amount', abs(v_plug) / v_header.rate_to_base, 'party_currency', v_return_ccy, 'party_rate', 1,
                'source_line_type', 'RETURN_VALUE_ADJUSTMENT'
            ));
        END IF;
    END IF;

    -- 7. Post whichever vouchers are needed. Both tag the same
    --    source_doc_type/source_doc_no, so the Posted Journal Entries
    --    section finds either or both with no extra plumbing.
    IF jsonb_array_length(v_jv_lines) > 0 THEN
        SELECT trans_no, trans_date INTO v_jv_trans_no, v_jv_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'JV', p_return_date,
            v_jv_lines, 'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
        );
    END IF;

    IF jsonb_array_length(v_sdn_lines) > 0 THEN
        SELECT trans_no, trans_date INTO v_sdn_trans_no, v_sdn_trans_date FROM fn_post_voucher(
            p_client_id, p_company_id, v_header.location_id, 'SDN', p_return_date,
            v_sdn_lines, 'PURCHASE_RETURN', p_return_no, p_return_date, p_approved_by
        );
    END IF;

    -- 8. Recompute status of every PO touched by this return, ONLY if the
    --    caller chose to reopen — qty_received itself already moved above
    --    regardless of this flag.
    IF p_reopen_po THEN
        FOR v_po_key IN
            SELECT DISTINCT gl.source_po_order_no, gl.source_po_order_date
            FROM rid_purchase_return_lines l
            JOIN rid_grn_lines gl
              ON gl.client_id = l.client_id AND gl.company_id = l.company_id
             AND gl.grn_no = l.source_grn_no AND gl.grn_date = l.source_grn_date
             AND gl.serial_no = l.source_grn_line_serial
            WHERE l.client_id = p_client_id AND l.company_id = p_company_id
              AND l.return_no = p_return_no AND l.return_date = p_return_date AND l.is_deleted = false
              AND gl.source_po_order_no IS NOT NULL
        LOOP
            SELECT coalesce(sum(base_qty), 0), coalesce(sum(qty_received), 0)
            INTO v_po_total_ordered, v_po_total_received
            FROM rid_purchase_order_lines
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = v_po_key.source_po_order_no AND order_date = v_po_key.source_po_order_date
              AND is_deleted = false;

            v_po_any_short := v_po_total_received < v_po_total_ordered;

            UPDATE rih_purchase_orders SET
                status = CASE WHEN v_po_any_short THEN 'PARTIALLY_RECEIVED' ELSE 'CLOSED' END,
                closed_by = CASE WHEN v_po_any_short THEN NULL ELSE closed_by END,
                closed_at = CASE WHEN v_po_any_short THEN NULL ELSE closed_at END,
                updated_at = now(), updated_by = p_approved_by
            WHERE client_id = p_client_id AND company_id = p_company_id
              AND order_no = v_po_key.source_po_order_no AND order_date = v_po_key.source_po_order_date
              AND status IN ('APPROVED', 'PARTIALLY_RECEIVED', 'CLOSED');
        END LOOP;
    END IF;

    -- 9. Mark the return approved. Primary voucher reference is the SDN if
    --    this return touched any billed GRN, else the JV.
    UPDATE rih_purchase_return_headers SET
        status = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        posted_voucher_no = coalesce(v_sdn_trans_no, v_jv_trans_no),
        posted_voucher_date = coalesce(v_sdn_trans_date, v_jv_trans_date),
        updated_at = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_purchase_return(UUID, UUID, TEXT, DATE, BOOLEAN, UUID) TO authenticated;
