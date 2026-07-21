-- ============================================================
-- Migration 103: Sales Executive Master
-- ============================================================
-- Flagged during Sales Delivery planning (2026-07-21) as the very next
-- follow-up: sales_person_id on Sales Quotation/Order/Invoice, and
-- default_sales_person_id on Quick Invoice Setup, were all hard FKs to
-- rim_users — forcing every salesperson to be a system login. Real
-- mismatch: field sales reps / commission agents are very often not
-- ERP users at all. Same precedent as SAP's own "Sales Employee" master
-- (independent of the SU01 system-user object, optionally linkable to
-- one) and every mid-market ERP's bare "Salesman" master.
--
-- rim_sales_executives is a flat master, no relational complexity
-- (unlike rim_customer_delivery_locations, which is keyed to a
-- customer) — id, employee_code, full_name, phone, email, an OPTIONAL
-- linked_user_id (nullable FK to rim_users, for the case a sales exec
-- genuinely is also a system user), is_active/is_deleted.
--
-- ── Zero-data-loss FK retrofit strategy ─────────────────────────────
-- Every already-saved sales_person_id/default_sales_person_id value is
-- currently a rim_users.id. Rather than rewriting those stored values
-- (touching every Quotation/Order/Invoice/Setup row ever saved), this
-- migration seeds a rim_sales_executives row using THE SAME id as the
-- corresponding rim_users row it's derived from — every existing
-- reference stays valid with zero data migration, because the new FK
-- target already contains a row at that exact id. linked_user_id is set
-- to that same rim_users.id, so these backfilled rows are also
-- immediately correct "this exec IS this system user" records, not
-- placeholders needing manual cleanup.
-- ============================================================

CREATE TABLE IF NOT EXISTS rim_sales_executives (
    id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID          NOT NULL REFERENCES ric_clients(id),
    company_id     UUID          NOT NULL REFERENCES ric_companies(id),
    employee_code  TEXT          NOT NULL,
    full_name      TEXT          NOT NULL,
    phone          TEXT,
    email          TEXT,
    -- Optional — only set when this sales executive also happens to be a
    -- system user. NULL is the normal case (a field rep with no login).
    linked_user_id UUID          REFERENCES rim_users(id),
    is_active      BOOLEAN       NOT NULL DEFAULT true,
    is_deleted     BOOLEAN       NOT NULL DEFAULT false,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by     UUID          REFERENCES rim_users(id),
    updated_at     TIMESTAMPTZ,
    updated_by     UUID          REFERENCES rim_users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sales_executives_code
    ON rim_sales_executives (client_id, company_id, employee_code)
    WHERE is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_sales_executives_tenant
    ON rim_sales_executives (client_id, company_id, is_active)
    WHERE is_deleted = false;

DROP TRIGGER IF EXISTS trg_rim_sales_executives_updated_at ON rim_sales_executives;
CREATE TRIGGER trg_rim_sales_executives_updated_at
    BEFORE UPDATE ON rim_sales_executives
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE rim_sales_executives ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "auth_rw_sales_executives" ON rim_sales_executives;
CREATE POLICY "auth_rw_sales_executives" ON rim_sales_executives
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON rim_sales_executives FROM anon;
GRANT SELECT, INSERT, UPDATE ON rim_sales_executives TO authenticated;


-- ── Backfill: one rim_sales_executives row per rim_users row ever
-- referenced as a sales_person_id/default_sales_person_id, using the
-- SAME id so every existing reference stays valid with no data rewrite.
INSERT INTO rim_sales_executives (id, client_id, company_id, employee_code, full_name, phone, email, linked_user_id, is_active, created_by)
SELECT u.id, u.client_id, u.company_id, u.username, u.full_name, u.phone, u.email, u.id, u.is_active, u.id
FROM rim_users u
WHERE u.id IN (
    SELECT sales_person_id FROM rih_sales_quotations WHERE sales_person_id IS NOT NULL
    UNION
    SELECT sales_person_id FROM rih_sales_orders WHERE sales_person_id IS NOT NULL
    UNION
    SELECT sales_person_id FROM rih_sales_invoices WHERE sales_person_id IS NOT NULL
    UNION
    SELECT default_sales_person_id FROM ric_user_quick_invoice_setup WHERE default_sales_person_id IS NOT NULL
)
ON CONFLICT (id) DO NOTHING;


-- ── Retrofit the FK target on all four columns ──────────────────────
ALTER TABLE rih_sales_quotations DROP CONSTRAINT IF EXISTS rih_sales_quotations_sales_person_id_fkey;
ALTER TABLE rih_sales_quotations ADD CONSTRAINT rih_sales_quotations_sales_person_id_fkey
    FOREIGN KEY (sales_person_id) REFERENCES rim_sales_executives(id);

ALTER TABLE rih_sales_orders DROP CONSTRAINT IF EXISTS rih_sales_orders_sales_person_id_fkey;
ALTER TABLE rih_sales_orders ADD CONSTRAINT rih_sales_orders_sales_person_id_fkey
    FOREIGN KEY (sales_person_id) REFERENCES rim_sales_executives(id);

ALTER TABLE rih_sales_invoices DROP CONSTRAINT IF EXISTS rih_sales_invoices_sales_person_id_fkey;
ALTER TABLE rih_sales_invoices ADD CONSTRAINT rih_sales_invoices_sales_person_id_fkey
    FOREIGN KEY (sales_person_id) REFERENCES rim_sales_executives(id);

ALTER TABLE ric_user_quick_invoice_setup DROP CONSTRAINT IF EXISTS ric_user_quick_invoice_setup_default_sales_person_id_fkey;
ALTER TABLE ric_user_quick_invoice_setup ADD CONSTRAINT ric_user_quick_invoice_setup_default_sales_person_id_fkey
    FOREIGN KEY (default_sales_person_id) REFERENCES rim_sales_executives(id);

-- No fn_save_sales_quotation/fn_save_sales_order/fn_save_sales_invoice
-- changes needed — all three already treat sales_person_id as a plain
-- passthrough UUID (no validation logic beyond the FK itself), confirmed
-- by reading each function's current body (087/097's own CREATE OR
-- REPLACE for Order/Invoice, 081's original for Quotation, still the
-- latest — no later override exists).


-- ── Menu seeding for existing companies: SL-EXE under Pricing & Setup ──
-- No prior placeholder existed (confirmed against ric_master_menus) —
-- seated alongside SL-PRC (Price Master), same group.
INSERT INTO ric_master_menus (
    client_id, company_id, module_id, feature_code, feature_name, screen_name,
    serial_no, group_code, group_name, group_serial_no,
    approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT co.client_id, co.id, sm.id, 'SL-EXE', 'Sales Executives', '/sales/sales-executives',
       1, 'SL-MST', 'Pricing & Setup', 0, false, false, false
FROM ric_companies co
JOIN ric_system_modules sm ON sm.client_id = co.client_id AND sm.company_id = co.id AND sm.module_code = 'SL'
ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
    SET group_code      = excluded.group_code,
        group_name      = excluded.group_name,
        group_serial_no = excluded.group_serial_no;
