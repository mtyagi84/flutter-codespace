-- ============================================================
-- Migration 094: Customer/Supplier Category as controlled-vocabulary
-- common masters, replacing free-text entry on Customer Master /
-- Supplier Master.
-- ============================================================
-- Two SEPARATE type_keys (not one shared "PARTY_CATEGORY") since the
-- example values genuinely differ per party type. `rim_accounts.
-- party_category` stays a plain TEXT column -- unchanged -- it is also
-- written to as free text by fn_convert_prospect_to_customer (087,
-- Sales Order's own prospect-capture flow), which is out of scope
-- here; converting party_category to a real FK would ripple into that
-- unrelated screen. This migration only adds a controlled-vocabulary
-- SOURCE for the value at entry time on the two Master screens -- same
-- reuse of the existing generic mechanism (rim_common_master_types/
-- rim_common_masters) as Incoterm (086) and Brand/Unit/Color before it.
-- Same seed-every-existing-company shape as Incoterm's own migration
-- 086 PART 3 -- category values aren't company-specific data, but
-- still seeded per-company (not globally) so an admin can add/deactivate
-- per company via the existing Common Masters screen.
-- ============================================================

INSERT INTO rim_common_master_types (type_key, type_name) VALUES
    ('CUSTOMER_CATEGORY', 'Customer Category'),
    ('SUPPLIER_CATEGORY', 'Supplier Category')
ON CONFLICT (type_key) DO NOTHING;

DO $$
DECLARE
    v_customer_type_id UUID;
    v_supplier_type_id UUID;
    v_company RECORD;
    v_value   TEXT;
    v_customer_values TEXT[] := ARRAY['Retail','Wholesale','Distributor','Corporate','Government'];
    v_supplier_values TEXT[] := ARRAY['Local','Imported','Manufacturer','Distributor','Service Provider'];
BEGIN
    SELECT id INTO v_customer_type_id FROM rim_common_master_types WHERE type_key = 'CUSTOMER_CATEGORY';
    SELECT id INTO v_supplier_type_id FROM rim_common_master_types WHERE type_key = 'SUPPLIER_CATEGORY';

    FOR v_company IN SELECT id, client_id FROM ric_companies
    LOOP
        FOREACH v_value IN ARRAY v_customer_values
        LOOP
            INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
            SELECT v_company.client_id, v_company.id, v_customer_type_id, v_value, array_position(v_customer_values, v_value)
            WHERE NOT EXISTS (
                SELECT 1 FROM rim_common_masters
                WHERE client_id = v_company.client_id AND company_id = v_company.id
                  AND type_id = v_customer_type_id AND description = v_value
            );
        END LOOP;

        FOREACH v_value IN ARRAY v_supplier_values
        LOOP
            INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
            SELECT v_company.client_id, v_company.id, v_supplier_type_id, v_value, array_position(v_supplier_values, v_value)
            WHERE NOT EXISTS (
                SELECT 1 FROM rim_common_masters
                WHERE client_id = v_company.client_id AND company_id = v_company.id
                  AND type_id = v_supplier_type_id AND description = v_value
            );
        END LOOP;
    END LOOP;
END $$;
