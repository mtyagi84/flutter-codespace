-- ============================================================
-- fn_seed_client_modules
-- Seeds default ERP modules and master menus for a new company.
-- Safe to re-run: ON CONFLICT DO NOTHING for modules;
-- ON CONFLICT DO UPDATE backfills group columns on features.
-- Called automatically from fn_register_client.
-- ============================================================
-- Rewritten 2026-08-05 as part of the Settings/Masters reorg (migration
-- 128). Every module's own master data used to be dumped into Admin's
-- "Master Data" group; now Sales/Purchase/Inventory/Finance keep ONLY
-- Transactions + Reports, and ALL configuration/masters live under one
-- "Settings" area (module_code still 'AD', module_name now 'Settings') —
-- organized into System Setup, User Management, and one Masters group
-- per business module (Sales Masters/Purchase Masters/Inventory Masters/
-- Finance Masters).
--
-- This rewrite also reconciled against a real export of the live
-- ric_master_menus table (Current_master.csv, 2026-08-05), which
-- surfaced two real gaps this file alone could never have shown:
-- 1. NINE working screens (routes confirmed live in app_router.dart)
--    had been patched directly into Supabase and never added here at
--    all: AD-CNT (Country Setup), AD-DIV (Country Divisions), AD-CIT
--    (Cities), AD-PDT (Print Templates), AD-ACT (Accounting Setup),
--    AD-ULS (User Location Setup), AD-MST (Master Menu — the tool that
--    edits ric_master_menus itself), AD-PCS (Product Category Level
--    Setup), AD-PGS (Product Flag Types), FN-EX (Exchange Rates). All
--    added below.
-- 2. ~15 duplicate/stray rows had accumulated from iterative rebuilding
--    (same screen_name under 2+ different feature_codes) plus one real
--    bug: the live PR-PO pointed at /purchase/order-entry, a route that
--    no longer exists anywhere in app_router.dart (confirmed via grep —
--    zero matches) — fixed to /purchase/orders, the real list screen,
--    matching this app's Menu->List->Entry convention (entry screens are
--    never menu targets). None of that stray data is reproduced here —
--    migration 128 wipes ric_master_menus/ric_user_menus and reseeds
--    from this file alone, safe because the app is still pre-production
--    (one client, one company, one user, nothing to preserve).
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
    -- AD's display name is now 'Settings' — it still holds true
    -- system-wide config (System Setup, User Management) but is also
    -- now home to every OTHER module's own Masters group.
    -- --------------------------------------------------------
    insert into ric_system_modules (client_id, company_id, module_code, module_name, serial_no)
    values
        (p_client_id, p_company_id, 'AD', 'Settings',   0),
        (p_client_id, p_company_id, 'SL', 'Sales',      1),
        (p_client_id, p_company_id, 'PR', 'Purchase',   2),
        (p_client_id, p_company_id, 'IN', 'Inventory',  3),
        (p_client_id, p_company_id, 'FN', 'Finance',    4)
    on conflict (client_id, company_id, module_code) do update
        set module_name = excluded.module_name;

    select id into v_ad from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'AD';
    select id into v_sl from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'SL';
    select id into v_pr from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'PR';
    select id into v_in from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'IN';
    select id into v_fn from ric_system_modules where client_id = p_client_id and company_id = p_company_id and module_code = 'FN';

    -- --------------------------------------------------------
    -- AD / Settings — System Setup
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'AD-CMP',     'Company Setup',           '/setup/company',                0, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-LOC',     'Location Setup',          '/setup/locations',               1, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-CUR',     'Currency Setup',          '/setup/currencies',              2, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PDC',     'Period Close',            '/setup/period-close',            3, 'AD-SETG', 'System Setup', 0, true,  false, false),
        (p_client_id, p_company_id, v_ad, 'AD-BDC',     'Backdated Entry Control', '/setup/backdated-entry-control', 4, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-QIS',     'Quick Invoice Setup',     '/setup/quick-invoice-setup',     5, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-CNT',     'Country Setup',           '/setup/countries',               6, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-DIV',     'Country Divisions',       '/setup/divisions',               7, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-CIT',     'Cities',                  '/setup/cities',                  8, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PDT',     'Print Templates',         '/setup/print-templates',         9, 'AD-SETG', 'System Setup', 0, false, true,  false),
        (p_client_id, p_company_id, v_ad, 'AD-ACT',     'Accounting Setup',        '/setup/accounting',              10, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-CMN',    'Common Masters',          '/master/common-masters',         11, 'AD-SETG', 'System Setup', 0, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PAYTERM', 'Payment Terms',           '/master/payment-terms',          12, 'AD-SETG', 'System Setup', 0, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- AD / Settings — User Management
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'AD-USR', 'User Management',     '/setup/users',                 0, 'AD-USMG', 'User Management', 1, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PRM', 'User Permissions',    '/setup/permissions',            1, 'AD-USMG', 'User Management', 1, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-ULS', 'User Location Setup', '/setup/user-location-access',   2, 'AD-USMG', 'User Management', 1, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-MST', 'Master Menu',         '/setup/master-menu',            3, 'AD-USMG', 'User Management', 1, false, true,  false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- AD / Settings — Sales Masters
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'MST-CUST', 'Customer Master',   '/master/customers',        0, 'SL-MST', 'Sales Masters', 2, false, false, false),
        (p_client_id, p_company_id, v_ad, 'SL-PRC',   'Price Master',      '/sales/price-master',      1, 'SL-MST', 'Sales Masters', 2, true,  false, false),
        (p_client_id, p_company_id, v_ad, 'SL-EXE',   'Sales Executives',  '/sales/sales-executives',  2, 'SL-MST', 'Sales Masters', 2, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- AD / Settings — Purchase Masters
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'MST-SUPP', 'Supplier Master', '/master/suppliers', 0, 'PR-MST', 'Purchase Masters', 3, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- AD / Settings — Inventory Masters
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'MST-PRD', 'Product Master',                '/master/products',                         0, 'IN-MST', 'Inventory Masters', 4, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-ITC', 'Item Categories',               '/master/item-categories',                  1, 'IN-MST', 'Inventory Masters', 4, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PCS',  'Product Category Level Setup',  '/setup/category-levels',                   2, 'IN-MST', 'Inventory Masters', 4, false, false, false),
        (p_client_id, p_company_id, v_ad, 'AD-PGS',  'Product Flag Types',            '/setup/product-flag-types',                3, 'IN-MST', 'Inventory Masters', 4, false, false, false),
        (p_client_id, p_company_id, v_ad, 'IN-DCA',  'Consumption Area Setup',        '/inventory/department-consumption-areas',  4, 'IN-MST', 'Inventory Masters', 4, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- AD / Settings — Finance Masters
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_ad, 'MST-COA', 'Chart of Accounts',   '/master/accounts',            0, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-TAX', 'Tax Master',          '/master/tax-master',          1, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-TXG', 'Tax Groups',          '/master/tax-groups',          2, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-ALS', 'Account Link Setup',  '/master/account-link-setup',  3, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-IAL', 'Item Account Links',  '/master/item-account-links',  4, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-CHG', 'Additional Charges',  '/master/additional-charges',  5, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'FN-EX',   'Exchange Rates',      '/finance/exchange-rates',     6, 'FN-MST', 'Finance Masters', 5, false, false, false),
        (p_client_id, p_company_id, v_ad, 'MST-OB',  'Opening Balance',     '/master/opening-balances',    7, 'FN-MST', 'Finance Masters', 5, false, false, true)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- SL — Sales (Transactions + Reports only — masters moved to Settings)
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_sl, 'SL-QUO', 'Sales Quotation',    '/sales/quotations',        0, 'SL-TXN', 'Transactions', 0, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-SO',  'Sales Order',        '/sales/orders',            1, 'SL-TXN', 'Transactions', 0, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-INV', 'Sales Invoice',      '/sales/invoices',          2, 'SL-TXN', 'Transactions', 0, true,  true,  false),
        (p_client_id, p_company_id, v_sl, 'SL-INR', 'Pending Approvals',  '/sales/pending-approvals', 3, 'SL-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_sl, 'SL-RET', 'Sales Return',       '/sales/returns',           4, 'SL-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_sl, 'SL-DEL', 'Sales Delivery',     '/sales/deliveries',        5, 'SL-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_sl, 'SL-RCP', 'Cash Receipt',       '/sales/receipts',          6, 'SL-TXN', 'Transactions', 0, false, false, false),
        (p_client_id, p_company_id, v_sl, 'SL-RPT-REG', 'Sales Register', '/reports/SALES_REGISTER',  0, 'SL-RPT', 'Reports',      1, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- PR — Purchase (Transactions only — Supplier Master moved to Settings)
    -- PR-PO's screen_name fixed to /purchase/orders (the real list
    -- screen) — the live DB had it pointing at /purchase/order-entry,
    -- a route confirmed no longer present anywhere in app_router.dart.
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
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- IN — Inventory (Transactions + Reports only — masters moved to
    -- Settings). Group renamed from "Operations" to "Transactions" for
    -- naming consistency with every other module.
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_in, 'IN-STK', 'Stock List',             '/inventory/stock',                    0, 'IN-OPS', 'Transactions', 0, false, false, false),
        (p_client_id, p_company_id, v_in, 'IN-TRF', 'Stock Transfer',         '/inventory/transfers',                1, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-ADJ', 'Stock Adjustment',       '/inventory/adjustments',              2, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-MRQ', 'Material Requisition',   '/inventory/requisitions',             3, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-MIS', 'Material Issue',         '/inventory/material-issue',           4, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-STR', 'Stock Transfer Request', '/inventory/stock-transfer-requests',  5, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-SRC', 'Stock Receipt',          '/inventory/stock-receipts',           6, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-OPN', 'Opening Stock',          '/inventory/opening-stock',            7, 'IN-OPS', 'Transactions', 0, true,  false, true),
        (p_client_id, p_company_id, v_in, 'IN-CNT', 'Stock Count',            '/inventory/stock-count',              8, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-CNR', 'Stock Count Review',     '/inventory/stock-count-review',       9, 'IN-OPS', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_in, 'IN-RPT-SBM', 'Stock Balance by Location', '/reports/STOCK_BALANCE_MATRIX', 0, 'IN-RPT', 'Reports',     1, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
            group_name      = excluded.group_name,
            group_serial_no = excluded.group_serial_no;

    -- --------------------------------------------------------
    -- FN — Finance (Transactions + Reports only — masters moved to Settings)
    -- --------------------------------------------------------
    insert into ric_master_menus
        (client_id, company_id, module_id, feature_code, feature_name, screen_name,
         serial_no, group_code, group_name, group_serial_no,
         approve_allowed, copy_allowed, excel_upload_allowed)
    values
        (p_client_id, p_company_id, v_fn, 'FN-JRN', 'Journal Entry',            '/finance/journal',            0, 'FN-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_fn, 'FN-CTR', 'Contra Voucher',           '/finance/contra',             1, 'FN-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_fn, 'FN-EXP', 'Expense Voucher',          '/finance/expense-vouchers',   2, 'FN-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_fn, 'FN-CBK', 'Cash Book',                '/finance/cashbook',           3, 'FN-TXN', 'Transactions', 0, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-PRV', 'Payment/Receipt Voucher',  '/finance/voucher-list',       4, 'FN-TXN', 'Transactions', 0, true,  false, false),
        (p_client_id, p_company_id, v_fn, 'FN-TRB', 'Trial Balance',            '/finance/trial-balance',      0, 'FN-RPT', 'Reports',      1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-PNL', 'Profit & Loss',            '/reports/PROFIT_LOSS_SUMMARY', 1, 'FN-RPT', 'Reports',     1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-BSH', 'Balance Sheet',            '/finance/balance-sheet',      2, 'FN-RPT', 'Reports',      1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-PBR', 'Pending Bills Register',      '/reports/PENDING_BILLS_REGISTER',      3, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-PBG', 'Pending Bills by Customer',   '/reports/PENDING_BILLS_BY_CUSTOMER',   4, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-LDG', 'Account Ledger',              '/reports/ACCOUNT_LEDGER',              5, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-CAG', 'Customer Ageing',             '/reports/CUSTOMER_AGEING',             7, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-SAG', 'Supplier Ageing',             '/reports/SUPPLIER_AGEING',             8, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-PBS', 'Pending Bills by Supplier',   '/reports/PENDING_BILLS_BY_SUPPLIER',   9, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-EXR', 'Expense Report',              '/reports/EXPENSE_REPORT_MATRIX',       10, 'FN-RPT', 'Reports', 1, false, false, false),
        (p_client_id, p_company_id, v_fn, 'FN-RPT-PNL', 'Profit & Loss Account Detail', '/reports/PROFIT_LOSS_DETAIL',          11, 'FN-RPT', 'Reports', 1, false, false, false)
    on conflict (client_id, company_id, feature_code) do update
        set module_id       = excluded.module_id,
            feature_name    = excluded.feature_name,
            screen_name     = excluded.screen_name,
            serial_no       = excluded.serial_no,
            group_code      = excluded.group_code,
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
