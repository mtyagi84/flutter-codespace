-- ============================================================
-- Migration 191: "Bulk Upload Products" — dedicated menu entry
-- ============================================================
-- Supersedes the simple Upload Excel button migration 190 added to the
-- Product Master screen (MST-PRD) -- the user asked for a genuinely
-- complete, dedicated screen instead (staging grid, auto-creates
-- Category/Item Size/Item Color/Brand/Unit masters, batch tax-group
-- confirmation, end-of-run cleanup of unused auto-created masters). Same
-- menu-wiring recipe as migration 133's own Opening Balance rollout.
--
-- MST-PRD's own excel_upload_allowed is reverted back to false here --
-- the simple button/methods were removed from product_list_screen.dart
-- in the same session, so a lingering true flag there would be dead
-- config with no UI reading it. MST-COA (Chart of Accounts bulk upload,
-- also added in migration 190) is untouched -- that feature is unrelated
-- and still fully in use.
-- ============================================================

DO $$
DECLARE
    v_company RECORD;
    v_ad_module_id UUID;
BEGIN
    FOR v_company IN SELECT id AS company_id, client_id FROM ric_companies LOOP

        SELECT id INTO v_ad_module_id FROM ric_system_modules
            WHERE client_id = v_company.client_id AND company_id = v_company.company_id AND module_code = 'AD';

        CONTINUE WHEN v_ad_module_id IS NULL;

        INSERT INTO ric_master_menus
            (client_id, company_id, module_id, feature_code, feature_name, screen_name,
             serial_no, group_code, group_name, group_serial_no, approve_allowed, copy_allowed, excel_upload_allowed)
        VALUES
            (v_company.client_id, v_company.company_id, v_ad_module_id, 'MST-BUP', 'Bulk Upload Products',
             '/master/bulk-upload-products', 5, 'IN-MST', 'Inventory Masters', 4, false, false, true)
        ON CONFLICT (client_id, company_id, feature_code) DO UPDATE
            SET screen_name = excluded.screen_name, group_code = excluded.group_code,
                group_name = excluded.group_name, group_serial_no = excluded.group_serial_no,
                serial_no = excluded.serial_no, excel_upload_allowed = excluded.excel_upload_allowed;

    END LOOP;
END $$;

-- ric_user_menus backfill — give view+edit+excel_upload to whoever already
-- has edit access to any other AD-module feature (same pattern as 133).
INSERT INTO ric_user_menus (
    client_id, company_id, user_id, module_id, feature_code, serial_no,
    view_allowed, edit_allowed, approve_allowed, copy_allowed, excel_upload_allowed
)
SELECT DISTINCT
    mm.client_id, mm.company_id, existing.user_id, mm.module_id, mm.feature_code, mm.serial_no,
    true, true, mm.approve_allowed, mm.copy_allowed, mm.excel_upload_allowed
FROM ric_master_menus mm
JOIN (
    SELECT DISTINCT user_id, client_id, company_id, module_id
    FROM ric_user_menus
    WHERE edit_allowed = true AND is_deleted = false
) existing
    ON  existing.client_id  = mm.client_id
    AND existing.company_id = mm.company_id
    AND existing.module_id  = mm.module_id
WHERE mm.feature_code = 'MST-BUP'
  AND mm.is_deleted = false
ON CONFLICT (client_id, company_id, user_id, feature_code) DO UPDATE
    SET view_allowed = true, edit_allowed = true, excel_upload_allowed = true, updated_at = now();

-- Revert MST-PRD's excel_upload_allowed (set true by migration 190) --
-- the simple button it gated was removed from product_list_screen.dart.
UPDATE ric_master_menus
SET    excel_upload_allowed = false
WHERE  feature_code = 'MST-PRD'
  AND  is_deleted = false;

UPDATE ric_user_menus
SET    excel_upload_allowed = false,
       updated_at = now()
WHERE  feature_code = 'MST-PRD'
  AND  is_deleted = false;
