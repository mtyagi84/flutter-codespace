-- ============================================================
-- Migration 043: Generic Print Template Engine — schema
-- ============================================================
-- One template engine for every document type (Purchase Order, Finance
-- Voucher today; GRN/Quotation/RFQ/Sales Order/Invoice/POS Receipt later)
-- instead of a bespoke PDF builder per screen (which is what Finance
-- Voucher had until this migration — see VoucherPdfBuilder, being retired
-- in this same session).
--
-- Design:
--   document_type   is free TEXT, not a CHECK-constrained enum — a brand
--                    new document type (e.g. a future POS Receipt screen)
--                    registers itself just by using a new string; no schema
--                    change needed to support it.
--   paper_profile    picks which of the two renderers applies:
--                      A4 / LETTER        -> canvas renderer (elements at
--                                            absolute x/y, in millimetres)
--                      RECEIPT_58MM/80MM  -> flow renderer (elements stack
--                                            top-to-bottom, full width,
--                                            no x/y — a receipt has no
--                                            meaningful horizontal space to
--                                            position things in)
--                    Both share the same element/layout JSON shape; the
--                    renderer just interprets x/y/w/h differently (canvas)
--                    or ignores them and uses array order (flow).
--   layout           JSONB — ordered element list. See
--                    lib/core/printing/print_models.dart for the Dart-side
--                    shape (kept in sync manually, no JSON-schema
--                    validation at the DB level — this is authored content,
--                    not transactional data).
--   is_default       one default per (client, company, document_type),
--                    enforced by the partial unique index below. Multiple
--                    NAMED templates per document type are allowed
--                    (e.g. "Formal PO" vs "Compact PO") — the default is
--                    just which one prints when nothing else is picked.
--   Fallback         if a company has ZERO active templates for a
--                    document_type (new company, or before anyone has
--                    visited the designer screen), the app falls back to a
--                    hardcoded Dart-side default (see
--                    lib/core/printing/default_templates/) — printing
--                    always works, even before this table has a single row.
--
-- is_active IS appropriate on THIS table (unlike the PO/GRN/Voucher LINE
-- tables, which deliberately don't have one — see migration 042's
-- comment): a print template is a reusable, independently-toggleable
-- entity, not a line inside one transaction — the same reasoning that
-- gives rim_additional_charges/rim_products an is_active column.
--
-- Objects:
--   ric_print_templates  → table
-- ============================================================

CREATE TABLE IF NOT EXISTS ric_print_templates (
    id             UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id      UUID          NOT NULL REFERENCES ric_clients(id),
    company_id     UUID          NOT NULL REFERENCES ric_companies(id),
    document_type  TEXT          NOT NULL,
    template_name  TEXT          NOT NULL,
    paper_profile  TEXT          NOT NULL
                   CHECK (paper_profile IN ('A4', 'LETTER', 'RECEIPT_58MM', 'RECEIPT_80MM')),
    is_default     BOOLEAN       NOT NULL DEFAULT false,
    layout         JSONB         NOT NULL,
    is_active      BOOLEAN       NOT NULL DEFAULT true,
    is_deleted     BOOLEAN       NOT NULL DEFAULT false,
    created_at     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by     UUID          REFERENCES rim_users(id),
    updated_at     TIMESTAMPTZ,
    updated_by     UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, document_type, template_name)
);

-- Only one default template per (client, company, document_type) — a
-- partial unique index rather than a CHECK since "at most one TRUE" can't
-- be expressed as a row-level CHECK constraint.
CREATE UNIQUE INDEX IF NOT EXISTS uq_print_templates_one_default
    ON ric_print_templates (client_id, company_id, document_type)
    WHERE is_default = true AND is_deleted = false;

CREATE INDEX IF NOT EXISTS idx_print_templates_lookup
    ON ric_print_templates (client_id, company_id, document_type, is_active, is_deleted);

CREATE TRIGGER trg_ric_print_templates_updated_at
    BEFORE UPDATE ON ric_print_templates
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

ALTER TABLE ric_print_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_rw_print_templates" ON ric_print_templates
    FOR ALL TO authenticated
    USING     (client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid)
    WITH CHECK(client_id  = (current_setting('request.jwt.claims', true)::json->>'client_id')::uuid
           AND company_id = (current_setting('request.jwt.claims', true)::json->>'company_id')::uuid);

REVOKE ALL ON ric_print_templates FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ric_print_templates TO authenticated;
