-- Migration 236: Customer/Supplier Master Report leaked non-posting GROUP
-- accounts (e.g. the "Customers"/"Suppliers" parent header under which real
-- customer/supplier leaves are created) alongside real party rows.
--
-- Found live 2026-10-31 during the Phase 1 browser-E2E pass: the Customer
-- Master Report showed a row "4110 — Customers" (the group header itself,
-- `posting_allowed=false`) with every detail column blank, next to the one
-- real test customer. Same defect confirmed on the Supplier Master Report
-- ("4010 — Suppliers"). Root cause: v_party_master_report (migration 169)
-- filters only on `account_nature IN ('Customer','Supplier')` and
-- `is_deleted=false` — it never excludes non-posting (group/header) rows,
-- which share the same account_nature as their postable children.
--
-- Fix: add `a.posting_allowed = true` to the view's WHERE clause. A
-- master-data report should only ever list real, transactable parties —
-- never the chart-of-accounts group structure those parties are filed
-- under. security_invoker=true is preserved (CREATE OR REPLACE VIEW does
-- not reset it, but re-stated explicitly per this project's own
-- documented convention of never trusting that detail silently).

CREATE OR REPLACE VIEW v_party_master_report AS
SELECT a.client_id,
    a.company_id,
    a.account_code,
    a.account_name,
    a.account_nature,
    a.party_type,
    a.party_category,
    a.contact_person,
    a.phone,
    a.email,
    a.address_line1,
    a.address_line2,
    city.city_name,
    country.country_name,
    cur.currency_id AS ledger_currency_code,
    a.tax_id,
    a.credit_limit,
    a.credit_days,
    a.is_credit_blocked,
    a.is_active
FROM rim_accounts a
LEFT JOIN rim_cities city ON city.id = a.city_id
LEFT JOIN rim_countries country ON country.id = a.country_id
LEFT JOIN rim_currencies cur ON cur.id = a.account_currency_id
WHERE a.is_deleted = false
  AND a.posting_allowed = true
  AND a.account_nature = ANY (ARRAY['Customer'::text, 'Supplier'::text]);

ALTER VIEW v_party_master_report SET (security_invoker = true);

GRANT SELECT ON v_party_master_report TO anon, authenticated, service_role;
