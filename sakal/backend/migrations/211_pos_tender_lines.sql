-- ============================================================================
-- Migration 211: multi-currency split tender for POS cash sales
-- ============================================================================
-- Lets a cashier record a cash sale as collected across MULTIPLE currencies
-- (e.g. part in CDF, part in USD) — a real gap flagged since this module's
-- very first design pass (docs/pos/03_payments_multicurrency.md) and left
-- deliberately unbuilt pending this follow-up.
--
-- Deliberately a RECORD-KEEPING table only, not a GL-splitting mechanism:
-- `fn_post_voucher`/`fn_post_finance_voucher` enforce "one voucher, one
-- trans_currency" throughout this schema (see CLAUDE.md's own "Concurrency"
-- and Purchase Bill sections) — a single settlement voucher can never post
-- legs in two different currencies. fn_save_sales_invoice/
-- fn_approve_sales_invoice are therefore UNCHANGED: `collected_amount_local`
-- on the invoice header still carries the single total (computed client-side
-- as the sum of every tender line's own local-currency equivalent), and the
-- existing settlement voucher continues to post exactly as it always has.
-- This table exists purely so the CASH DRAWER's own reconciliation (Shift &
-- Cash, POS Reports) can show what was actually handed over, per currency —
-- the same "this is a UX/reconciliation aid, the real postings are
-- unaffected" shape already used for Stock Adjustment Register's own
-- cost-visibility split.
--
-- A future pass that wants genuine multi-currency GL settlement (e.g. two
-- real receipt vouchers, one per tender currency, each independently
-- reducing the same customer bill via the existing generic pending-bills
-- mechanism — same shape as Purchase Bill's PUR+EXC split) can build on top
-- of this table without any schema change here.
-- ============================================================================

CREATE TABLE IF NOT EXISTS rid_pos_tender_lines (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id         UUID NOT NULL REFERENCES ric_clients(id),
    company_id        UUID NOT NULL REFERENCES ric_companies(id),
    invoice_no        TEXT NOT NULL,
    invoice_date      DATE NOT NULL,
    serial_no         SMALLINT NOT NULL,
    tender_type       TEXT NOT NULL DEFAULT 'CASH' CHECK (tender_type IN ('CASH')),
    currency_id       TEXT NOT NULL,
    amount            NUMERIC(18,4) NOT NULL CHECK (amount > 0),
    rate_to_local     NUMERIC(18,6) NOT NULL DEFAULT 1,
    amount_local      NUMERIC(18,4) NOT NULL,
    is_deleted        BOOLEAN NOT NULL DEFAULT false,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by        UUID REFERENCES rim_users(id),
    CONSTRAINT uq_pos_tender_line UNIQUE (client_id, company_id, invoice_no, invoice_date, serial_no)
);

CREATE INDEX IF NOT EXISTS idx_pos_tender_lines_invoice ON rid_pos_tender_lines (client_id, company_id, invoice_no, invoice_date);

DROP POLICY IF EXISTS "auth_rw_rid_pos_tender_lines" ON rid_pos_tender_lines;
CREATE POLICY "auth_rw_rid_pos_tender_lines" ON rid_pos_tender_lines
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);
ALTER TABLE rid_pos_tender_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rid_pos_tender_lines FROM anon;
GRANT SELECT, INSERT ON rid_pos_tender_lines TO authenticated;
