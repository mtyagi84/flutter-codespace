-- ============================================================
-- fn_seed_client_modules
-- Seeds default ERP modules and master menus for a new company.
-- Called automatically from fn_register_client.
-- Can also be called manually by SAKAL admin for new companies
-- added after initial registration.
-- ============================================================

create or replace function fn_seed_client_modules(
    p_client_id      uuid,
    p_company_id     uuid,
    p_admin_user_id  uuid default null
) returns void language plpgsql security definer as $$
declare
    v_ad uuid; v_sl uuid; v_pr uuid; v_in uuid; v_fn uuid;
begin
    -- --------------------------------------------------------
    -- Modules (AD=0, SL=1, PR=2, IN=3, FN=4)
    -- AD is serial 0 so it always appears first in sidebar
    -- --------------------------------------------------------
    insert into ric_system_modules
        (client_id, company_id, module_code, module_name, serial_no)
    values
        (p_client_id, p_company_id, 'AD', 'Administration', 0),
        (p_client_id, p_company_id, 'SL', 'Sales',          1),
        (p_client_id, p_company_id, 'PR', 'Purchase',        2),
        (p_client_id, p_company_id, 'IN', 'Inventory',       3),
        (p_client_id, p_company_id, 'FN', 'Finance',         4);

    -- Capture module IDs for foreign keys
    select id into v_ad from ric_system_modules
    where client_id = p_client_id and company_id = p_company_id and module_code = 'AD';

    select id into v_sl from ric_system_modules
    where client_id = p_client_id and company_id = p_company_id and module_code = 'SL';

    select id into v_pr from ric_system_modules
    where client_id = p_client_id and company_id = p_company_id and module_code = 'PR';

    select id into v_in from ric_system_modules
    where client_id = p_client_id and company_id = p_company_id and module_code = 'IN';

    select id into v_fn from ric_system_modules
    where client_id = p_client_id and company_id = p_company_id and module_code = 'FN';

    -- --------------------------------------------------------
    -- Master Menus — Administration
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name, serial_no)
    values
        (p_client_id, p_company_id, v_ad, 'AD-USR', 'User Management',  '/setup/users',       1),
        (p_client_id, p_company_id, v_ad, 'AD-PRM', 'User Permissions', '/setup/permissions', 2),
        (p_client_id, p_company_id, v_ad, 'AD-CMP', 'Company Setup',    '/setup/company',     3),
        (p_client_id, p_company_id, v_ad, 'AD-LOC', 'Location Setup',   '/setup/locations',   4),
        (p_client_id, p_company_id, v_ad, 'AD-CUR', 'Currency Setup',   '/setup/currencies',  5);

    -- --------------------------------------------------------
    -- Master Menus — Sales
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, copy_allowed, approve_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_sl, 'SL-INV', 'Sales Invoice',  '/sales/invoices',      1, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-RET', 'Sales Return',   '/sales/returns',       2, false, false, false),
        (p_client_id, p_company_id, v_sl, 'SL-RCP', 'Cash Receipt',   '/sales/receipts',      3, false, false, false);

    -- --------------------------------------------------------
    -- Master Menus — Purchase
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, copy_allowed, approve_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_pr, 'PR-PO',  'Purchase Order',    '/purchase/orders',    1, true,  true,  false),
        (p_client_id, p_company_id, v_pr, 'PR-GRN', 'Goods Receipt',     '/purchase/grn',       2, false, true,  false),
        (p_client_id, p_company_id, v_pr, 'PR-INV', 'Purchase Invoice',  '/purchase/invoices',  3, true,  false, false),
        (p_client_id, p_company_id, v_pr, 'PR-PAY', 'Supplier Payment',  '/purchase/payments',  4, false, false, false);

    -- --------------------------------------------------------
    -- Master Menus — Inventory
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, copy_allowed, approve_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_in, 'IN-STK', 'Stock List',        '/inventory/stock',       1, false, false, false),
        (p_client_id, p_company_id, v_in, 'IN-TRF', 'Stock Transfer',    '/inventory/transfers',   2, false, true,  false),
        (p_client_id, p_company_id, v_in, 'IN-ADJ', 'Stock Adjustment',  '/inventory/adjustments', 3, false, true,  false);

    -- --------------------------------------------------------
    -- Master Menus — Finance
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, copy_allowed, approve_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_fn, 'FN-JRN', 'Journal Entry',  '/finance/journal',        1, false, true,  false),
        (p_client_id, p_company_id, v_fn, 'FN-CBK', 'Cash Book',      '/finance/cashbook',       2, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-TRB', 'Trial Balance',  '/finance/trial-balance',  3, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-PNL', 'Profit & Loss',  '/finance/profit-loss',    4, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-BSH', 'Balance Sheet',  '/finance/balance-sheet',  5, false, false, false);

    -- --------------------------------------------------------
    -- Grant full admin access to first user (if provided)
    -- --------------------------------------------------------
    if p_admin_user_id is not null then
        perform fn_grant_admin_access(p_admin_user_id, p_client_id, p_company_id);
    end if;

end;
$$;
