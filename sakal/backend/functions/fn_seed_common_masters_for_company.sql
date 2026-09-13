-- ============================================================
-- fn_seed_common_masters_for_company
--
-- Same bug class as fn_seed_report_definitions_for_company: four
-- migrations (064 Purchase Return Reason, 076 Stock Adjustment Reason,
-- 086 Incoterm, 094 Customer/Supplier Category) each seeded default
-- rim_common_masters VALUE rows only for companies that existed AT THE
-- TIME that migration ran ("INSERT ... SELECT FROM ric_companies" /
-- "FOR v_company IN SELECT ... FROM ric_companies LOOP"), and none of
-- that seeding was ever wired into fn_register_client -- every company
-- registered since gets an empty dropdown for these five lookups.
--
-- Also folds in the bare-minimum starter values the user asked for on
-- top of that fix, so a brand-new (typically small) tenant isn't
-- staring at empty Brand/UOM/Color/Item-Category pickers on day one:
--   - UNIT (UOM):  PCS, KG, LTR, BOX
--   - BRAND:       Generic
--   - COLOR:       N/A
--   - rim_category_levels level 1 ("Category") + the 8 standard
--     rim_product_flag_types (identical values to
--     ProductFlagTypeModel.defaults() in
--     lib/features/master/data/models/product_flag_type_model.dart --
--     the Flutter "Load Defaults" button) + one "General" item
--     category at level 1 carrying those flags, so a product can be
--     created immediately without a trip to Category/Flag setup first.
--
-- Called once per new company registration (wired into
-- fn_register_client below), scoped directly to the one company being
-- registered -- unlike the four migrations above, this never needs a
-- loop over ric_companies or a future backfill migration.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_seed_common_masters_for_company(
    p_client_id  UUID,
    p_company_id UUID
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_purchase_return_reason_type UUID;
    v_stock_adjustment_reason_type UUID;
    v_incoterm_type UUID;
    v_customer_category_type UUID;
    v_supplier_category_type UUID;
    v_unit_type UUID;
    v_brand_type UUID;
    v_color_type UUID;
    v_category_flags JSONB;
BEGIN
    SELECT id INTO v_purchase_return_reason_type FROM rim_common_master_types WHERE type_key = 'PURCHASE_RETURN_REASON';
    SELECT id INTO v_stock_adjustment_reason_type FROM rim_common_master_types WHERE type_key = 'STOCK_ADJUSTMENT_REASON';
    SELECT id INTO v_incoterm_type FROM rim_common_master_types WHERE type_key = 'INCOTERM';
    SELECT id INTO v_customer_category_type FROM rim_common_master_types WHERE type_key = 'CUSTOMER_CATEGORY';
    SELECT id INTO v_supplier_category_type FROM rim_common_master_types WHERE type_key = 'SUPPLIER_CATEGORY';
    SELECT id INTO v_unit_type FROM rim_common_master_types WHERE type_key = 'UNIT';
    SELECT id INTO v_brand_type FROM rim_common_master_types WHERE type_key = 'BRAND';
    SELECT id INTO v_color_type FROM rim_common_master_types WHERE type_key = 'COLOR';

    -- ── 1. Purchase Return Reason (064) ─────────────────────────────────────
    IF v_purchase_return_reason_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        SELECT p_client_id, p_company_id, v_purchase_return_reason_type, v.description, v.sort_order
        FROM (VALUES
            ('Defective', 1), ('Wrong Item Supplied', 2), ('Excess Delivery', 3),
            ('Quality Issue', 4), ('Data Entry Correction', 5), ('Other', 6)
        ) AS v(description, sort_order)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    -- ── 2. Stock Adjustment Reason (076) ────────────────────────────────────
    IF v_stock_adjustment_reason_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        SELECT p_client_id, p_company_id, v_stock_adjustment_reason_type, v.description, v.sort_order
        FROM (VALUES
            ('Damage', 1), ('Expiry', 2), ('Theft / Shrinkage', 3),
            ('Physical Count Variance', 4), ('Data Entry Correction', 5), ('Other', 6)
        ) AS v(description, sort_order)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    -- ── 3. Incoterm (086) ────────────────────────────────────────────────────
    IF v_incoterm_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        SELECT p_client_id, p_company_id, v_incoterm_type, v.code, v.sort_order
        FROM (VALUES
            ('EXW',1),('FCA',2),('CPT',3),('CIP',4),('DAP',5),
            ('DPU',6),('DDP',7),('FAS',8),('FOB',9),('CFR',10),('CIF',11)
        ) AS v(code, sort_order)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    -- ── 4. Customer / Supplier Category (094) ───────────────────────────────
    IF v_customer_category_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        SELECT p_client_id, p_company_id, v_customer_category_type, v.description, v.sort_order
        FROM (VALUES ('Retail',1),('Wholesale',2),('Distributor',3),('Corporate',4),('Government',5)) AS v(description, sort_order)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    IF v_supplier_category_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        SELECT p_client_id, p_company_id, v_supplier_category_type, v.description, v.sort_order
        FROM (VALUES ('Local',1),('Imported',2),('Manufacturer',3),('Distributor',4),('Service Provider',5)) AS v(description, sort_order)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    -- ── 5. Bare-minimum UOM / Brand / Color starter values ──────────────────
    -- These type_keys (022_common_masters.sql) were always deliberately left
    -- with zero default VALUES for every tenant, admin-filled -- the user
    -- explicitly asked for a bare-minimum starter set instead, since most
    -- tenants are small companies that shouldn't need a Common Masters visit
    -- before they can create their first product.
    IF v_unit_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        SELECT p_client_id, p_company_id, v_unit_type, v.description, v.sort_order
        FROM (VALUES ('PCS',1),('KG',2),('LTR',3),('BOX',4)) AS v(description, sort_order)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    IF v_brand_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        VALUES (p_client_id, p_company_id, v_brand_type, 'Generic', 1)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    IF v_color_type IS NOT NULL THEN
        INSERT INTO rim_common_masters (client_id, company_id, type_id, description, sort_order)
        VALUES (p_client_id, p_company_id, v_color_type, 'N/A', 1)
        ON CONFLICT (client_id, company_id, type_id, description) DO NOTHING;
    END IF;

    -- ── 6. Category Level 1 + standard Product Flag Types ───────────────────
    -- Same 8 flags/values as ProductFlagTypeModel.defaults() (the Flutter
    -- "Load Defaults" button) -- reproduced here so a fresh tenant already
    -- has them without a manual visit to Product Flag Types setup.
    INSERT INTO rim_category_levels (client_id, company_id, level_no, level_label, is_mandatory, sort_order)
    VALUES (p_client_id, p_company_id, 1, 'Category', true, 1)
    ON CONFLICT (client_id, company_id, level_no) DO NOTHING;

    INSERT INTO rim_product_flag_types (client_id, company_id, flag_key, flag_label, default_value, sort_order)
    SELECT p_client_id, p_company_id, v.flag_key, v.flag_label, v.default_value, v.sort_order
    FROM (VALUES
        ('is_saleable',          'Can be Sold',                  true,  1),
        ('is_purchasable',       'Can be Purchased',             true,  2),
        ('is_pos_item',          'Appears on POS Screen',        true,  3),
        ('is_discountable',      'Discount Allowed',             true,  4),
        ('is_transferable',      'Warehouse Transfer Allowed',   true,  5),
        ('is_intercompany',      'Intercompany Transfer Allowed',false, 6),
        ('allow_negative_stock', 'Allow Negative Stock',         false, 7),
        ('is_consignment',       'Consignment Stock',            false, 8)
    ) AS v(flag_key, flag_label, default_value, sort_order)
    ON CONFLICT (client_id, company_id, flag_key) DO NOTHING;

    -- rim_item_categories has no usable ON CONFLICT target for a NULL
    -- parent_id (Postgres never matches NULL against NULL in a UNIQUE
    -- constraint, so a plain ON CONFLICT would silently re-insert a
    -- duplicate "General" row on every re-run) -- guard with NOT EXISTS.
    v_category_flags := jsonb_build_object(
        'is_saleable', true, 'is_purchasable', true, 'is_pos_item', true,
        'is_discountable', true, 'is_transferable', true,
        'is_intercompany', false, 'allow_negative_stock', false, 'is_consignment', false
    );
    INSERT INTO rim_item_categories (client_id, company_id, parent_id, level_no, category_name, flags, sort_order)
    SELECT p_client_id, p_company_id, NULL, 1, 'General', v_category_flags, 1
    WHERE NOT EXISTS (
        SELECT 1 FROM rim_item_categories
        WHERE client_id = p_client_id AND company_id = p_company_id
          AND parent_id IS NULL AND category_name = 'General'
    );
END;
$$;

GRANT EXECUTE ON FUNCTION fn_seed_common_masters_for_company(UUID, UUID) TO authenticated;
