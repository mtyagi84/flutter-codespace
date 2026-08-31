-- ============================================================
-- Migration 174: Bank Reconciliation — schema (Format Master, Bank
-- Accounts, Bank Statement header/lines) + Save/Approve functions
-- ============================================================
-- First of three Bank Reconciliation migrations. Full design discussed
-- and approved with the user — see sakal/docs/screens/plan_bank_reconciliation.md
-- for the complete rationale. This is a genuine from-scratch feature (no
-- bank-statement/reconciliation concept existed anywhere in this schema
-- before now), sized differently from every reporting-only batch this
-- session — real new tables + Flutter screens follow in later steps, not
-- just migrations.
--
-- NO GL posting anywhere in this migration — a Bank Statement is a
-- reference document (what the bank says happened), same "no financial
-- impact" category as Sales Quotation/Price Master. Reconciliation
-- matching (migration 175) never touches rid_finance_lines either — it
-- only records WHICH existing book lines correspond to WHICH statement
-- lines, a pure cross-reference.
-- ============================================================

-- ── New voucher type: BSTMT (numbering only, no posting) ────────────────
INSERT INTO rim_voucher_types (
    voucher_type_code, type_description, voucher_nature,
    cash_bank_side, reset_frequency, trans_no_format, is_system
) VALUES
    ('BSTMT', 'Bank Statement', 'JOURNAL', NULL, 'YEARLY', '{TYPE}/{LOC}/{YYYY}/{SEQ5}', true)
ON CONFLICT DO NOTHING;


-- ============================================================
-- rim_bank_statement_formats — the Format Master. One row per bank (or
-- per bank+account if a bank varies), configured once by an admin and
-- reused on every upload for that bank.
-- ============================================================
CREATE TABLE IF NOT EXISTS rim_bank_statement_formats (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL REFERENCES ric_clients(id),
    company_id        UUID          NOT NULL REFERENCES ric_companies(id),
    format_name       TEXT          NOT NULL,
    file_type         TEXT          NOT NULL CHECK (file_type IN ('CSV', 'EXCEL', 'PDF')),
    -- Rows/lines to skip before real transaction data starts (bank
    -- letterhead, account summary header, column-title row itself if the
    -- mapping below uses column INDEX rather than header name).
    header_skip_rows  INTEGER       NOT NULL DEFAULT 0,
    -- CSV/EXCEL: maps to the source column HEADER NAME (e.g. "Withdrawal
    -- Amt"). PDF: maps to column ORDER/position since there's no reliable
    -- header text to key off (e.g. "3" = third detected column).
    -- Keys: txn_no, txn_date, remarks, debit, credit, running_balance.
    column_mapping    JSONB         NOT NULL DEFAULT '{}',
    -- Banks vary DD/MM/YYYY vs MM/DD/YYYY vs YYYY-MM-DD.
    date_format       TEXT          NOT NULL DEFAULT 'DD/MM/YYYY',
    is_active         BOOLEAN       NOT NULL DEFAULT true,
    is_deleted        BOOLEAN       NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    updated_at        TIMESTAMPTZ,
    updated_by        UUID          REFERENCES rim_users(id)
);

CREATE INDEX IF NOT EXISTS idx_bank_statement_formats_tenant ON rim_bank_statement_formats (client_id, company_id, is_deleted);

DROP TRIGGER IF EXISTS trg_rim_bank_statement_formats_updated_at ON rim_bank_statement_formats;
CREATE TRIGGER trg_rim_bank_statement_formats_updated_at
    BEFORE UPDATE ON rim_bank_statement_formats
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_bank_statement_formats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_bank_statement_formats" ON rim_bank_statement_formats;
CREATE POLICY "auth_rw_bank_statement_formats" ON rim_bank_statement_formats
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_bank_statement_formats FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_bank_statement_formats TO authenticated;


-- ============================================================
-- rim_bank_accounts — one row per Bank-nature rim_accounts row that needs
-- reconciliation. Not every Bank account necessarily gets one (a company
-- may choose not to reconcile a dormant account).
-- ============================================================
CREATE TABLE IF NOT EXISTS rim_bank_accounts (
    id                UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID          NOT NULL REFERENCES ric_clients(id),
    company_id        UUID          NOT NULL REFERENCES ric_companies(id),
    account_id        UUID          NOT NULL REFERENCES rim_accounts(id),
    bank_name         TEXT          NOT NULL,
    account_number    TEXT,
    branch_name       TEXT,
    ifsc_swift_code   TEXT,
    default_format_id UUID          REFERENCES rim_bank_statement_formats(id),
    is_active         BOOLEAN       NOT NULL DEFAULT true,
    is_deleted        BOOLEAN       NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by        UUID          REFERENCES rim_users(id),
    updated_at        TIMESTAMPTZ,
    updated_by        UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rim_bank_accounts_account UNIQUE (client_id, company_id, account_id)
);

CREATE INDEX IF NOT EXISTS idx_bank_accounts_tenant ON rim_bank_accounts (client_id, company_id, is_deleted);

DROP TRIGGER IF EXISTS trg_rim_bank_accounts_updated_at ON rim_bank_accounts;
CREATE TRIGGER trg_rim_bank_accounts_updated_at
    BEFORE UPDATE ON rim_bank_accounts
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_bank_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_bank_accounts" ON rim_bank_accounts;
CREATE POLICY "auth_rw_bank_accounts" ON rim_bank_accounts
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_bank_accounts FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_bank_accounts TO authenticated;


-- ============================================================
-- rih_bank_statement_headers — one row per uploaded statement batch.
-- location_id is a plain column (per-location numbering input, same
-- shape as Sales Quotation/Price Master) — not part of the header's own
-- composite identity.
-- ============================================================
CREATE TABLE IF NOT EXISTS rih_bank_statement_headers (
    id                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id          UUID          NOT NULL REFERENCES ric_clients(id),
    company_id         UUID          NOT NULL REFERENCES ric_companies(id),
    location_id        UUID          NOT NULL REFERENCES ric_locations(id),
    statement_no       TEXT          NOT NULL,
    statement_date     DATE          NOT NULL,
    bank_account_id    UUID          NOT NULL REFERENCES rim_bank_accounts(id),
    period_from        DATE          NOT NULL,
    period_to          DATE          NOT NULL,
    source_file_type   TEXT          NOT NULL CHECK (source_file_type IN ('CSV', 'EXCEL', 'PDF')),
    opening_balance    NUMERIC(18,4) NOT NULL DEFAULT 0,
    closing_balance    NUMERIC(18,4) NOT NULL DEFAULT 0,
    -- DRAFT = uploaded, lines may still need review if PDF-sourced.
    -- APPROVED = confirmed correct, ready for reconciliation matching.
    -- No GL impact at either status.
    status             TEXT          NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT', 'APPROVED')),
    approved_by        UUID          REFERENCES rim_users(id),
    approved_at        TIMESTAMPTZ,
    remarks            TEXT,
    is_active          BOOLEAN       NOT NULL DEFAULT true,
    is_deleted         BOOLEAN       NOT NULL DEFAULT false,
    created_at         TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by         UUID          REFERENCES rim_users(id),
    updated_at         TIMESTAMPTZ,
    updated_by         UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rih_bank_statement_headers UNIQUE (client_id, company_id, statement_no, statement_date),
    CONSTRAINT chk_bank_statement_period CHECK (period_to >= period_from)
);

CREATE INDEX IF NOT EXISTS idx_bank_statement_headers_tenant  ON rih_bank_statement_headers (client_id, company_id, is_deleted);
CREATE INDEX IF NOT EXISTS idx_bank_statement_headers_account ON rih_bank_statement_headers (bank_account_id, period_from, period_to);

DROP TRIGGER IF EXISTS trg_rih_bank_statement_headers_updated_at ON rih_bank_statement_headers;
CREATE TRIGGER trg_rih_bank_statement_headers_updated_at
    BEFORE UPDATE ON rih_bank_statement_headers
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rih_bank_statement_headers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_bank_statement_headers" ON rih_bank_statement_headers;
CREATE POLICY "auth_rw_bank_statement_headers" ON rih_bank_statement_headers
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rih_bank_statement_headers FROM anon;
GRANT SELECT, INSERT, UPDATE ON rih_bank_statement_headers TO authenticated;


-- ============================================================
-- rid_bank_statement_lines — one row per statement transaction, exactly
-- as printed on the bank's own statement.
-- ============================================================
CREATE TABLE IF NOT EXISTS rid_bank_statement_lines (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID          NOT NULL REFERENCES ric_clients(id),
    company_id       UUID          NOT NULL REFERENCES ric_companies(id),
    statement_no     TEXT          NOT NULL,
    statement_date   DATE          NOT NULL,
    serial_no        INTEGER       NOT NULL,
    txn_no           TEXT,
    txn_date         DATE          NOT NULL,
    remarks          TEXT,
    debit_amount     NUMERIC(18,4) NOT NULL DEFAULT 0,
    credit_amount    NUMERIC(18,4) NOT NULL DEFAULT 0,
    running_balance  NUMERIC(18,4),
    -- Only meaningful for PDF-sourced lines (see source_file_type on the
    -- header) — true once the user has confirmed/corrected this row.
    -- CSV/EXCEL lines are set true at Save time (already real table data,
    -- no review step needed).
    is_reviewed      BOOLEAN       NOT NULL DEFAULT true,
    is_deleted       BOOLEAN       NOT NULL DEFAULT false,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by       UUID          REFERENCES rim_users(id),
    updated_at       TIMESTAMPTZ,
    updated_by       UUID          REFERENCES rim_users(id),
    CONSTRAINT uq_rid_bank_statement_lines UNIQUE (client_id, company_id, statement_no, statement_date, serial_no),
    CONSTRAINT rid_bank_statement_lines_header_fk
        FOREIGN KEY (client_id, company_id, statement_no, statement_date)
        REFERENCES  rih_bank_statement_headers (client_id, company_id, statement_no, statement_date),
    CONSTRAINT chk_bank_statement_line_amount CHECK (
        (debit_amount = 0 AND credit_amount > 0) OR (debit_amount > 0 AND credit_amount = 0)
    )
);

CREATE INDEX IF NOT EXISTS idx_bank_statement_lines_header ON rid_bank_statement_lines (client_id, company_id, statement_no, statement_date);

ALTER TABLE rid_bank_statement_lines ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_bank_statement_lines" ON rid_bank_statement_lines;
CREATE POLICY "auth_rw_bank_statement_lines" ON rid_bank_statement_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rid_bank_statement_lines FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON rid_bank_statement_lines TO authenticated;


-- ============================================================
-- fn_save_bank_statement — DRAFT-only save. Mirrors fn_save_sales_quotation's
-- shape exactly (no GL/stock impact, lines deleted+reinserted each save).
-- CSV/EXCEL lines are trusted immediately (is_reviewed defaults true);
-- PDF lines come in flagged is_reviewed=false by the client and only flip
-- to true once the user explicitly confirms them in the Upload & Review
-- screen (a subsequent plain UPDATE, not re-running this whole function).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_save_bank_statement(
    p_header  JSONB,
    p_lines   JSONB,
    p_user_id UUID
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_client_id          UUID;
    v_company_id         UUID;
    v_location_id        UUID;
    v_statement_no       TEXT;
    v_statement_date     DATE;
    v_old_statement_date DATE;
    v_old_status         TEXT;
    v_is_new             BOOLEAN;
    v_line               JSONB;
BEGIN
    v_client_id      := (p_header->>'client_id')::uuid;
    v_company_id     := (p_header->>'company_id')::uuid;
    v_location_id    := (p_header->>'location_id')::uuid;
    v_statement_no   := nullif(trim(p_header->>'statement_no'), '');
    v_statement_date := (p_header->>'statement_date')::date;
    v_is_new         := v_statement_no IS NULL;

    IF jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Add at least one line to save a Bank Statement.';
    END IF;

    IF v_is_new THEN
        v_statement_no := fn_next_trans_no(v_client_id, v_company_id, v_location_id, 'BSTMT');
    ELSE
        SELECT statement_date, status INTO v_old_statement_date, v_old_status
        FROM   rih_bank_statement_headers
        WHERE  client_id = v_client_id AND company_id = v_company_id
          AND  statement_no = v_statement_no AND is_deleted = false
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Bank Statement % not found', v_statement_no;
        END IF;
        IF v_old_status != 'DRAFT' THEN
            RAISE EXCEPTION 'Bank Statement % is % and cannot be edited.', v_statement_no, v_old_status;
        END IF;

        DELETE FROM rid_bank_statement_lines
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND statement_no = v_statement_no AND statement_date = v_old_statement_date;
    END IF;

    IF v_is_new THEN
        INSERT INTO rih_bank_statement_headers (
            client_id, company_id, location_id, statement_no, statement_date, bank_account_id,
            period_from, period_to, source_file_type, opening_balance, closing_balance,
            remarks, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_location_id, v_statement_no, v_statement_date,
            (p_header->>'bank_account_id')::uuid,
            (p_header->>'period_from')::date, (p_header->>'period_to')::date,
            p_header->>'source_file_type',
            coalesce((p_header->>'opening_balance')::numeric, 0),
            coalesce((p_header->>'closing_balance')::numeric, 0),
            nullif(p_header->>'remarks', ''),
            p_user_id, p_user_id
        );
    ELSE
        UPDATE rih_bank_statement_headers SET
            location_id      = v_location_id,
            statement_date   = v_statement_date,
            bank_account_id  = (p_header->>'bank_account_id')::uuid,
            period_from      = (p_header->>'period_from')::date,
            period_to        = (p_header->>'period_to')::date,
            source_file_type = p_header->>'source_file_type',
            opening_balance  = coalesce((p_header->>'opening_balance')::numeric, 0),
            closing_balance  = coalesce((p_header->>'closing_balance')::numeric, 0),
            remarks          = nullif(p_header->>'remarks', ''),
            updated_at = now(), updated_by = p_user_id
        WHERE client_id = v_client_id AND company_id = v_company_id
          AND statement_no = v_statement_no AND status = 'DRAFT' AND is_deleted = false;
    END IF;

    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        INSERT INTO rid_bank_statement_lines (
            client_id, company_id, statement_no, statement_date, serial_no,
            txn_no, txn_date, remarks, debit_amount, credit_amount, running_balance,
            is_reviewed, created_by, updated_by
        ) VALUES (
            v_client_id, v_company_id, v_statement_no, v_statement_date,
            (v_line->>'serial_no')::integer,
            nullif(v_line->>'txn_no', ''),
            (v_line->>'txn_date')::date,
            nullif(v_line->>'remarks', ''),
            coalesce((v_line->>'debit_amount')::numeric, 0),
            coalesce((v_line->>'credit_amount')::numeric, 0),
            (v_line->>'running_balance')::numeric,
            coalesce((v_line->>'is_reviewed')::boolean, true),
            p_user_id, p_user_id
        );
    END LOOP;

    RETURN v_statement_no;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_save_bank_statement(JSONB, JSONB, UUID) TO authenticated;


-- ============================================================
-- fn_approve_bank_statement — no GL/stock impact, never posts. Blocked
-- while any line still needs review (relevant only for PDF-sourced
-- statements — CSV/EXCEL lines are always already is_reviewed=true).
-- ============================================================
CREATE OR REPLACE FUNCTION fn_approve_bank_statement(
    p_client_id      UUID,
    p_company_id     UUID,
    p_statement_no   TEXT,
    p_statement_date DATE,
    p_approved_by    UUID
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_header rih_bank_statement_headers%ROWTYPE;
    v_unreviewed_count INTEGER;
BEGIN
    SELECT * INTO v_header FROM rih_bank_statement_headers
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND statement_no = p_statement_no AND statement_date = p_statement_date
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bank Statement % dated % not found', p_statement_no, p_statement_date;
    END IF;
    IF v_header.status != 'DRAFT' THEN
        RAISE EXCEPTION 'Bank Statement % is % and cannot be approved again', p_statement_no, v_header.status;
    END IF;

    SELECT COUNT(*) INTO v_unreviewed_count
    FROM rid_bank_statement_lines
    WHERE client_id = p_client_id AND company_id = p_company_id
      AND statement_no = p_statement_no AND statement_date = p_statement_date
      AND is_deleted = false AND is_reviewed = false;

    IF v_unreviewed_count > 0 THEN
        RAISE EXCEPTION 'LINES_NOT_REVIEWED'
            USING DETAIL = format('%s line(s) extracted from the PDF still need review before this statement can be approved.', v_unreviewed_count);
    END IF;

    UPDATE rih_bank_statement_headers SET
        status      = 'APPROVED',
        approved_by = p_approved_by,
        approved_at = now(),
        updated_at  = now(), updated_by = p_approved_by
    WHERE id = v_header.id;
END;
$$;

GRANT EXECUTE ON FUNCTION fn_approve_bank_statement(UUID, UUID, TEXT, DATE, UUID) TO authenticated;


-- ============================================================
-- Menu seed — 'FN-BSF' (Bank Statement Format Master), 'FN-BAC' (Bank
-- Accounts), 'FN-BST' (Bank Statement Upload & Review) under a new
-- group_code 'FN-BRC' ("Bank Reconciliation") within the existing FN
-- module — for every already-existing company. fn_seed_client_modules.sql
-- updated separately for future clients.
-- ============================================================
DO $$
DECLARE
    v_company RECORD;
    v_fn_module_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_fn_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'FN';

        CONTINUE WHEN v_fn_module_id IS NULL;

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-BSF', 'Bank Statement Format Master', '/finance/bank-statement-formats', 0, 'FN-BRC', 'Bank Reconciliation', 9, false, false, false),
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-BAC', 'Bank Accounts', '/finance/bank-accounts', 1, 'FN-BRC', 'Bank Reconciliation', 9, false, false, false),
            (v_company.client_id, v_company.company_id, v_fn_module_id, 'FN-BST', 'Bank Statement Upload & Review', '/finance/bank-statements', 2, 'FN-BRC', 'Bank Reconciliation', 9, true, false, false)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code, group_name = excluded.group_name, group_serial_no = excluded.group_serial_no;

    END LOOP;
END $$ LANGUAGE plpgsql;


INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, false, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT user_id, client_id, company_id, module_id
    FROM ric_user_menus
    WHERE view_allowed = true AND is_deleted = false
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code IN ('FN-BSF', 'FN-BAC', 'FN-BST')
AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, updated_at = now();
