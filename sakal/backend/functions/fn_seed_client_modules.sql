-- ============================================================
-- fn_seed_client_modules
-- Seeds default ERP modules and master menus for a new company.
-- Safe to re-run: ON CONFLICT DO NOTHING for modules;
-- ON CONFLICT DO UPDATE backfills group columns on features.
-- Called automatically from fn_register_client.
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
    -- --------------------------------------------------------
    insert into ric_system_modules (client_id, company_id, module_code, module_name, serial_no)
    values
        (p_client_id, p_company_id, 'AD', 'Administration', 0),
        (p_client_id, p_company_id, 'SL', 'Sales',          1),
        (p_client_id, p_company_id, 'PR', 'Purchase',        2),
        (p_client_id, p_company_id, 'IN', 'Inventory',       3),
        (p_client_id, p_company_id, 'FN', 'Finance',         4)
    on conflict (client_id, company_id, module_code) do nothing;

    select id into v_ad from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'AD';
    select id into v_sl from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'SL';
    select id into v_pr from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'PR';
    select id into v_in from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'IN';
    select id into v_fn from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'FN';

    -- --------------------------------------------------------
    -- AD — Administration
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'AD-CMP', 'Company Setup',    '/setup/company',     0, 'AD-SETG', 'System Setup',    0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-LOC', 'Location Setup',   '/setup/locations',   1, 'AD-SETG', 'System Setup',    0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-CUR', 'Currency Setup',   '/setup/currencies',  2, 'AD-SETG', 'System Setup',    0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-USR', 'User Management',  '/setup/users',       0, 'AD-USMG', 'User Management', 1, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PRM', 'User Permissions', '/setup/permissions', 1, 'AD-USMG', 'User Management', 1, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PDC', 'Period Close',              '/setup/period-close',            3, 'AD-SETG', 'System Setup', 0, true,  false, false),
        (p_client_id, p_company_id, v_ad, 'AD-BDC', 'Backdated Entry Control',   '/setup/backdated-entry-control', 4, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PAYTERM', 'Payment Terms',         '/master/payment-terms',          5, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-QIS', 'Quick Invoice Setup',       '/setup/quick-invoice-setup',      6, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-CUST', 'Customer Master',        '/master/customers',  0, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-SUPP', 'Supplier Master',        '/master/suppliers',  1, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-COA',  'Chart of Accounts',      '/master/accounts',            2, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-ITC',  'Item Categories',        '/master/item-categories',     3, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-CMN',  'Common Masters',         '/master/common-masters',      4, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-TAX',  'Tax Master',             '/master/tax-master',          5, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-TXG',  'Tax Groups',             '/master/tax-groups',          6, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-CHG',  'Additional Charges',     '/master/additional-charges',  7, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-ALS',  'Account Link Setup',     '/master/account-link-setup',  8, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-IAL',  'Item Account Links',     '/master/item-account-links',  9, 'AD-MSTG', 'Master Data', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-PRD',  'Product Master',         '/master/products',           10, 'AD-MSTG', 'Master Data', 2, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- SL — Sales
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_sl, 'SL-PRC', 'Price Master',    '/sales/price-master', 0, 'SL-MST', 'Pricing & Setup', 0, true,  false, false),
        (p_client_id, p_company_id, v_sl, 'SL-QUO', 'Sales Quotation', '/sales/quotations', 0, 'SL-TXN', 'Transactions', 1, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-SO',  'Sales Order',     '/sales/orders',     1, 'SL-TXN', 'Transactions', 1, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-INV', 'Sales Invoice',   '/sales/invoices',   2, 'SL-TXN', 'Transactions', 1, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-INR', 'Sales Invoice - Manager Review', '/sales/invoice-manager-review', 3, 'SL-TXN', 'Transactions', 1, true, false, false),
        (p_client_id, p_company_id, v_sl, 'SL-RET', 'Sales Return',    '/sales/returns',    4, 'SL-TXN', 'Transactions', 1, true,  false, false),
        (p_client_id, p_company_id, v_sl, 'SL-RCP', 'Cash Receipt',    '/sales/receipts',   5, 'SL-TXN', 'Transactions', 1, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- PR — Purchase
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_pr, 'PR-PO',  'Purchase Order',   '/purchase/orders',   0, 'PR-TXN', 'Transactions', 0, true,  true,  false),
        (p_client_id, p_company_id, v_pr, 'PR-GRN', 'Goods Receipt',    '/purchase/grn',      1, 'PR-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_pr, 'PR-INV', 'Purchase Invoice', '/purchase/invoices', 2, 'PR-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_pr, 'PR-RET', 'Purchase Return',  '/purchase/returns',  3, 'PR-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_pr, 'PR-PAY', 'Supplier Payment', '/purchase/payments', 4, 'PR-TXN', 'Transactions', 0, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- IN — Inventory
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_in, 'IN-STK', 'Stock List',       '/inventory/stock',       0, 'IN-OPS', 'Operations', 0, false, false, false),
        (p_client_id, p_company_id, v_in, 'IN-TRF', 'Stock Transfer',   '/inventory/transfers',   1, 'IN-OPS', 'Operations', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-ADJ', 'Stock Adjustment', '/inventory/adjustments', 2, 'IN-OPS', 'Operations', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-MRQ', 'Material Requisition', '/inventory/requisitions',    3, 'IN-OPS',  'Operations', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-MIS', 'Material Issue',       '/inventory/material-issue',  4, 'IN-OPS',  'Operations', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-STR', 'Stock Transfer Request', '/inventory/stock-transfer-requests', 5, 'IN-OPS', 'Operations', 0, true, false, false),
        (p_client_id, p_company_id, v_in, 'IN-SRC', 'Stock Receipt',          '/inventory/stock-receipts',           6, 'IN-OPS', 'Operations', 0, true, false, false),
        (p_client_id, p_company_id, v_in, 'IN-OPN', 'Opening Stock',          '/inventory/opening-stock',            7, 'IN-OPS', 'Operations', 0, true, false, true),
        (p_client_id, p_company_id, v_in, 'IN-CNT', 'Stock Count',            '/inventory/stock-count',              8, 'IN-OPS', 'Operations', 0, true, false, false),
        (p_client_id, p_company_id, v_in, 'IN-CNR', 'Stock Count Review',     '/inventory/stock-count-review',       9, 'IN-OPS', 'Operations', 0, true, false, false),
        (p_client_id, p_company_id, v_in, 'IN-DCA', 'Consumption Area Setup', '/inventory/department-consumption-areas', 0, 'IN-SETG', 'Setup', 1, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- FN — Finance
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_fn, 'FN-JRN', 'Journal Entry', '/finance/journal',       0, 'FN-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_fn, 'FN-CBK', 'Cash Book',     '/finance/cashbook',      1, 'FN-TXN', 'Transactions', 0, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-TRB', 'Trial Balance', '/finance/trial-balance', 0, 'FN-RPT', 'Reports',      1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-PNL', 'Profit & Loss', '/finance/profit-loss',   1, 'FN-RPT', 'Reports',      1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-BSH', 'Balance Sheet', '/finance/balance-sheet', 2, 'FN-RPT', 'Reports',      1, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- Grant full admin access to first user (if provided)
    -- --------------------------------------------------------
    if p_admin_user_id is not null then
        perform fn_grant_admin_access(p_admin_user_id, p_client_id, p_company_id);
    end if;
end;
$$;
