-- ============================================================
-- Migration 064: Purchase Return Reason as a Common Master
-- ============================================================
-- Found live during first UI test: the entry screen's Reason field was
-- free text. Same pattern as PAYMENT_TERMS (040) / BRAND / UOM (022) —
-- rih_purchase_return_headers.reason stays a plain TEXT column (it's
-- always been a free-text audit label per the module's own design, never
-- a branch in the code), but the VALUE the user picks now comes from a
-- dropdown backed by rim_common_masters instead of a bare text field, so
-- reasons stay consistent across users/documents. Admins can add more
-- values any time via the existing Common Masters screen — no code change
-- needed for that.
-- ============================================================

INSERT INTO rim_common_master_types (type_key, type_name) VALUES
    ('PURCHASE_RETURN_REASON', 'Purchase Return Reason')
ON CONFLICT (type_key) DO NOTHING;

-- Seed a sensible default set for every existing company, so the dropdown
-- isn't empty on first use — same "seed for existing tenants" pattern
-- migration 062 used for the PR-RET menu item.
INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order, created_by)
SELECT co.client_id, co.id, t.id, v.description, v.sort_order, NULL
FROM ric_companies co
CROSS JOIN rim_common_master_types t
CROSS JOIN (VALUES
    ('Defective', 1),
    ('Wrong Item Supplied', 2),
    ('Excess Delivery', 3),
    ('Quality Issue', 4),
    ('Data Entry Correction', 5),
    ('Other', 6)
) AS v(description, sort_order)
WHERE t.type_key = 'PURCHASE_RETURN_REASON'
ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
