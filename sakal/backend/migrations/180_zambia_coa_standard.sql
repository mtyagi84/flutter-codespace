-- ============================================================
-- Migration 180: Zambia as a genuine third accounting standard
-- ============================================================
-- Part of the "new-tenant bare-minimum starter kit" initiative. Zambia is
-- one of this app's three real target markets (per CLAUDE.md) but had no
-- Chart of Accounts template of its own -- fn_seed_chart_of_accounts (013)
-- only ever had OHADA and INDIAN branches, and one existing code comment
-- (087_sales_order.sql:159) had assumed Zambia should just use OHADA. The
-- user explicitly chose a real third standard over that shortcut: Zambia's
-- accounting convention is IFRS-for-SMEs-based (English/common-law
-- tradition), structurally much closer to this schema's existing INDIAN
-- branch (Assets/Liabilities/Equity/Revenue/Expense) than to OHADA's
-- French numeric-class system -- so this branch mirrors INDIAN's shape
-- and granularity, with Zambia-appropriate account names: VAT Recoverable/
-- VAT Payable (Zambia's own VAT, not GST), PAYE & NAPSA Payable (Zambia's
-- payroll tax + pension authority, the local equivalent of "Employee
-- Liabilities"), and a Turnover Tax Expense line (Zambia's own small-
-- business alternative regime, distinct from VAT).
--
-- 1. Widen both accounting_std CHECK constraints to allow 'ZAMBIA'.
-- 2. CREATE OR REPLACE fn_seed_chart_of_accounts with the OHADA/INDIAN
--    branches reproduced verbatim (grepped from the latest live
--    definition in 013_chart_of_accounts.sql, never trust the original
--    CREATE for a function this central) plus a new ZAMBIA branch, plus
--    an ELSE guard that was missing before (an unrecognized p_std used to
--    silently seed zero accounts and still mark is_coa_seeded = TRUE).
-- ============================================================

ALTER TABLE rim_accounting_setup
    DROP CONSTRAINT IF EXISTS rim_accounting_setup_accounting_std_check,
    ADD  CONSTRAINT rim_accounting_setup_accounting_std_check
         CHECK (accounting_std IN ('INDIAN', 'OHADA', 'ZAMBIA'));

ALTER TABLE rim_accounts
    DROP CONSTRAINT IF EXISTS rim_accounts_accounting_std_check,
    ADD  CONSTRAINT rim_accounts_accounting_std_check
         CHECK (accounting_std IN ('INDIAN', 'OHADA', 'ZAMBIA'));

CREATE OR REPLACE FUNCTION fn_seed_chart_of_accounts(
    p_client_id  UUID,
    p_company_id UUID,
    p_std        TEXT
) RETURNS VOID AS $$
BEGIN
    CREATE TEMP TABLE _seed (
        code        TEXT,
        name        TEXT,
        parent_code TEXT,
        posting     BOOLEAN,
        nature      TEXT,
        new_id      UUID DEFAULT gen_random_uuid()
    ) ON COMMIT DROP;

    -- ── OHADA seed data ──────────────────────────────────────
    -- Source: Sakal_ERP_DRC_OHADA_CoA.xlsx  (Fixed rows only)
    IF p_std = 'OHADA' THEN
        INSERT INTO _seed (code, name, parent_code, posting, nature) VALUES
        -- Class 1 — Equity & Long-Term Financing
        ('1000', 'Class 1 - Equity & Long Term Financing', NULL,   FALSE, 'General'),
        ('1100', 'Reserves',                               '1000', FALSE, 'General'),
        ('1200', 'Retained Earnings',                      '1000', TRUE,  'General'),
        ('1300', 'Net Income',                             '1000', TRUE,  'General'),
        ('1600', 'Loans & Borrowings',                     '1000', FALSE, 'General'),
        -- Class 2 — Fixed Assets
        ('2000', 'Class 2 - Fixed Assets',                 NULL,   FALSE, 'General'),
        ('2100', 'Land',                                   '2000', TRUE,  'General'),
        ('2200', 'Buildings',                              '2000', TRUE,  'General'),
        ('2300', 'Technical Equipment',                    '2000', TRUE,  'General'),
        ('2400', 'Furniture & Equipment',                  '2000', TRUE,  'General'),
        ('2500', 'Transport Equipment',                    '2000', TRUE,  'General'),
        ('2700', 'Investments',                            '2000', TRUE,  'General'),
        ('2800', 'Accumulated Depreciation',               '2000', TRUE,  'General'),
        -- Class 3 — Inventory
        ('3000', 'Class 3 - Inventory',                    NULL,   FALSE, 'General'),
        ('3100', 'Raw Materials',                          '3000', FALSE, 'General'),
        ('3200', 'Other Supplies',                         '3000', FALSE, 'General'),
        ('3300', 'Work In Progress',                       '3000', TRUE,  'General'),
        ('3500', 'Finished Goods',                         '3000', FALSE, 'General'),
        ('3600', 'Merchandise',                            '3000', FALSE, 'General'),
        ('3700', 'Inventory In Transit',                   '3000', TRUE,  'General'),
        -- Class 4 — Third Parties
        ('4000', 'Class 4 - Third Parties',                NULL,   FALSE, 'General'),
        ('4010', 'Suppliers',                              '4000', FALSE, 'Supplier'),
        ('4110', 'Customers',                              '4000', FALSE, 'Customer'),
        ('4200', 'Personnel',                              '4000', FALSE, 'Employee'),
        ('4300', 'Social Security',                        '4000', TRUE,  'General'),
        ('4400', 'State & Taxes',                          '4000', FALSE, 'Tax'),
        -- Class 5 — Treasury
        ('5000', 'Class 5 - Treasury',                     NULL,   FALSE, 'General'),
        ('5100', 'Cash',                                   '5000', FALSE, 'Cash'),
        ('5200', 'Banks',                                  '5000', FALSE, 'Bank'),
        ('5800', 'Internal Transfers',                     '5000', TRUE,  'General'),
        -- Class 6 — Expenses
        ('6000', 'Class 6 - Expenses',                     NULL,   FALSE, 'General'),
        ('6100', 'Purchases',                              '6000', FALSE, 'General'),
        ('6200', 'External Services',                      '6000', FALSE, 'General'),
        ('6300', 'Taxes & Duties',                         '6000', TRUE,  'General'),
        ('6400', 'Personnel Costs',                        '6000', FALSE, 'General'),
        ('6500', 'Other Operating Expenses',               '6000', FALSE, 'General'),
        ('6600', 'Financial Charges',                      '6000', TRUE,  'General'),
        ('6800', 'Depreciation Expense',                   '6000', TRUE,  'General'),
        ('6900', 'Income Tax Expense',                     '6000', TRUE,  'General'),
        -- Class 7 — Revenue
        ('7000', 'Class 7 - Revenue',                      NULL,   FALSE, 'General'),
        ('7010', 'Sales of Goods',                         '7000', TRUE,  'General'),
        ('7100', 'Production Sold',                        '7000', TRUE,  'General'),
        ('7200', 'Service Revenue',                        '7000', TRUE,  'General'),
        ('7300', 'Inventory Variations',                   '7000', TRUE,  'General'),
        ('7600', 'Financial Revenue',                      '7000', TRUE,  'General'),
        -- Class 9 — Cost Accounting
        ('9000', 'Class 9 - Cost Accounting',              NULL,   FALSE, 'General'),
        ('9100', 'Production Centers',                     '9000', FALSE, 'General'),
        ('9200', 'Cost Allocation',                        '9000', FALSE, 'General'),
        ('9300', 'Manufacturing Cost',                     '9000', TRUE,  'General'),
        ('9400', 'Distribution Cost',                      '9000', TRUE,  'General'),
        ('9500', 'Administrative Cost',                    '9000', TRUE,  'General'),
        ('9700', 'Profit Centers',                         '9000', FALSE, 'General');

    -- ── Indian seed data ─────────────────────────────────────
    -- Source: Sakal_ERP_Revised_Indian_CoA.xlsx  (Fixed rows only)
    -- posting=FALSE on 1110/1120/1130/2110 so user-created
    -- Cash, Bank, Customer and Supplier ledgers can be added under them.
    ELSIF p_std = 'INDIAN' THEN
        INSERT INTO _seed (code, name, parent_code, posting, nature) VALUES
        -- Assets
        ('1000', 'Assets',                        NULL,   FALSE, 'General'),
        ('1100', 'Current Assets',                '1000', FALSE, 'General'),
        ('1110', 'Cash & Bank',                   '1100', FALSE, 'General'),
        ('1120', 'Trade Receivables',             '1100', FALSE, 'Customer'),
        ('1130', 'Inventory',                     '1100', FALSE, 'General'),
        ('1140', 'Tax Assets',                    '1100', TRUE,  'Tax'),
        ('1150', 'Advances & Deposits',           '1100', TRUE,  'General'),
        ('1160', 'Prepaid Expenses',              '1100', TRUE,  'General'),
        ('1170', 'Other Current Assets',          '1100', TRUE,  'General'),
        ('1200', 'Non Current Assets',            '1000', FALSE, 'General'),
        ('1210', 'Land',                          '1200', TRUE,  'General'),
        ('1220', 'Building',                      '1200', TRUE,  'General'),
        ('1230', 'Plant & Machinery',             '1200', TRUE,  'General'),
        ('1240', 'Furniture & Fixtures',          '1200', TRUE,  'General'),
        ('1250', 'Vehicles',                      '1200', TRUE,  'General'),
        ('1260', 'Computers & IT Equipment',      '1200', TRUE,  'General'),
        ('1270', 'Intangible Assets',             '1200', TRUE,  'General'),
        ('1280', 'Capital Work In Progress',      '1200', TRUE,  'General'),
        ('1290', 'Investments',                   '1200', TRUE,  'General'),
        -- Liabilities
        ('2000', 'Liabilities',                   NULL,   FALSE, 'General'),
        ('2100', 'Current Liabilities',           '2000', FALSE, 'General'),
        ('2110', 'Trade Payables',                '2100', FALSE, 'Supplier'),
        ('2120', 'Tax Liabilities',               '2100', TRUE,  'Tax'),
        ('2130', 'Employee Liabilities',          '2100', TRUE,  'Employee'),
        ('2140', 'Accrued Expenses',              '2100', TRUE,  'General'),
        ('2150', 'Customer Advances',             '2100', TRUE,  'General'),
        ('2160', 'Short Term Borrowings',         '2100', TRUE,  'General'),
        ('2170', 'Other Current Liabilities',     '2100', TRUE,  'General'),
        ('2200', 'Non Current Liabilities',       '2000', FALSE, 'General'),
        ('2210', 'Term Loans',                    '2200', TRUE,  'General'),
        ('2220', 'Lease Liabilities',             '2200', TRUE,  'General'),
        ('2230', 'Deferred Tax Liability',        '2200', TRUE,  'General'),
        -- Equity
        ('3000', 'Equity',                        NULL,   FALSE, 'General'),
        ('3100', 'Capital',                       '3000', FALSE, 'General'),
        ('3110', 'Share Capital',                 '3100', TRUE,  'General'),
        ('3120', 'Partner Capital',               '3100', TRUE,  'General'),
        ('3200', 'Reserves & Surplus',            '3000', FALSE, 'General'),
        ('3210', 'Retained Earnings',             '3200', TRUE,  'General'),
        ('3220', 'General Reserve',               '3200', TRUE,  'General'),
        -- Revenue
        ('4000', 'Revenue',                       NULL,   FALSE, 'General'),
        ('4100', 'Operating Revenue',             '4000', FALSE, 'General'),
        ('4110', 'Product Sales',                 '4100', TRUE,  'General'),
        ('4120', 'Service Revenue',               '4100', TRUE,  'General'),
        ('4130', 'Export Revenue',                '4100', TRUE,  'General'),
        ('4140', 'Scrap Sales',                   '4100', TRUE,  'General'),
        ('4150', 'Job Work Income',               '4100', TRUE,  'General'),
        ('4200', 'Non Operating Revenue',         '4000', FALSE, 'General'),
        ('4210', 'Interest Income',               '4200', TRUE,  'General'),
        ('4220', 'Commission Income',             '4200', TRUE,  'General'),
        ('4230', 'Rental Income',                 '4200', TRUE,  'General'),
        -- Expense
        ('5000', 'Expense',                       NULL,   FALSE, 'General'),
        ('5100', 'Cost Of Goods Sold',            '5000', FALSE, 'General'),
        ('5110', 'Raw Material Consumption',      '5100', TRUE,  'General'),
        ('5120', 'Packing Material Consumption',  '5100', TRUE,  'General'),
        ('5130', 'Direct Labour',                 '5100', TRUE,  'General'),
        ('5140', 'Factory Overheads',             '5100', TRUE,  'General'),
        ('5150', 'Subcontracting Charges',        '5100', TRUE,  'General'),
        ('5160', 'Production Variance',           '5100', TRUE,  'General'),
        ('5200', 'Operating Expense',             '5000', FALSE, 'General'),
        ('5210', 'Administrative Expenses',       '5200', TRUE,  'General'),
        ('5220', 'Selling & Distribution',        '5200', TRUE,  'General'),
        ('5230', 'IT Expenses',                   '5200', TRUE,  'General'),
        ('5240', 'HR Expenses',                   '5200', TRUE,  'General'),
        ('5250', 'Maintenance Expenses',          '5200', TRUE,  'General'),
        ('5300', 'Finance Cost',                  '5000', FALSE, 'General'),
        ('5310', 'Bank Charges',                  '5300', TRUE,  'General'),
        ('5320', 'Interest On Loan',              '5300', TRUE,  'General'),
        ('5330', 'Forex Loss',                    '5300', TRUE,  'General'),
        ('5400', 'Tax Expense',                   '5000', FALSE, 'General'),
        ('5410', 'Income Tax Expense',            '5400', TRUE,  'General'),
        ('5420', 'Deferred Tax Expense',          '5400', TRUE,  'General');

    -- ── Zambia seed data ─────────────────────────────────────
    -- IFRS-for-SMEs-shaped, same structural granularity as the Indian
    -- branch above (both English/common-law-tradition standards) --
    -- adapted with Zambia-specific line items: VAT (not GST), PAYE &
    -- NAPSA (Zambia's payroll tax + pension authority) instead of a
    -- generic Employee Liabilities line, and a Turnover Tax Expense line
    -- for Zambia's own small-business alternative tax regime.
    ELSIF p_std = 'ZAMBIA' THEN
        INSERT INTO _seed (code, name, parent_code, posting, nature) VALUES
        -- Assets
        ('1000', 'Assets',                        NULL,   FALSE, 'General'),
        ('1100', 'Current Assets',                '1000', FALSE, 'General'),
        ('1110', 'Cash & Bank',                   '1100', FALSE, 'General'),
        ('1120', 'Trade Receivables',             '1100', FALSE, 'Customer'),
        ('1130', 'Inventory',                     '1100', FALSE, 'General'),
        ('1140', 'VAT Recoverable',               '1100', TRUE,  'Tax'),
        ('1150', 'Advances & Prepayments',        '1100', TRUE,  'General'),
        ('1160', 'Other Current Assets',          '1100', TRUE,  'General'),
        ('1200', 'Non Current Assets',            '1000', FALSE, 'General'),
        ('1210', 'Land',                          '1200', TRUE,  'General'),
        ('1220', 'Buildings',                     '1200', TRUE,  'General'),
        ('1230', 'Plant & Machinery',             '1200', TRUE,  'General'),
        ('1240', 'Furniture & Fittings',          '1200', TRUE,  'General'),
        ('1250', 'Motor Vehicles',                '1200', TRUE,  'General'),
        ('1260', 'Computer & IT Equipment',       '1200', TRUE,  'General'),
        ('1270', 'Intangible Assets',             '1200', TRUE,  'General'),
        ('1280', 'Capital Work In Progress',      '1200', TRUE,  'General'),
        ('1290', 'Investments',                   '1200', TRUE,  'General'),
        -- Liabilities
        ('2000', 'Liabilities',                   NULL,   FALSE, 'General'),
        ('2100', 'Current Liabilities',           '2000', FALSE, 'General'),
        ('2110', 'Trade Payables',                '2100', FALSE, 'Supplier'),
        ('2120', 'VAT Payable',                   '2100', TRUE,  'Tax'),
        ('2130', 'PAYE & NAPSA Payable',          '2100', TRUE,  'Employee'),
        ('2140', 'Accrued Expenses',              '2100', TRUE,  'General'),
        ('2150', 'Customer Advances',             '2100', TRUE,  'General'),
        ('2160', 'Short Term Borrowings',         '2100', TRUE,  'General'),
        ('2170', 'Other Current Liabilities',     '2100', TRUE,  'General'),
        ('2200', 'Non Current Liabilities',       '2000', FALSE, 'General'),
        ('2210', 'Term Loans',                    '2200', TRUE,  'General'),
        ('2220', 'Lease Liabilities',             '2200', TRUE,  'General'),
        ('2230', 'Deferred Tax Liability',        '2200', TRUE,  'General'),
        -- Equity
        ('3000', 'Equity',                        NULL,   FALSE, 'General'),
        ('3100', 'Capital',                       '3000', FALSE, 'General'),
        ('3110', 'Share Capital',                 '3100', TRUE,  'General'),
        ('3120', 'Proprietor / Partner Capital',  '3100', TRUE,  'General'),
        ('3200', 'Reserves & Surplus',            '3000', FALSE, 'General'),
        ('3210', 'Retained Earnings',             '3200', TRUE,  'General'),
        ('3220', 'General Reserve',               '3200', TRUE,  'General'),
        -- Revenue
        ('4000', 'Revenue',                       NULL,   FALSE, 'General'),
        ('4100', 'Operating Revenue',             '4000', FALSE, 'General'),
        ('4110', 'Product Sales',                 '4100', TRUE,  'General'),
        ('4120', 'Service Revenue',               '4100', TRUE,  'General'),
        ('4130', 'Export Revenue',                '4100', TRUE,  'General'),
        ('4140', 'Scrap Sales',                   '4100', TRUE,  'General'),
        ('4200', 'Non Operating Revenue',         '4000', FALSE, 'General'),
        ('4210', 'Interest Income',               '4200', TRUE,  'General'),
        ('4220', 'Commission Income',             '4200', TRUE,  'General'),
        ('4230', 'Rental Income',                 '4200', TRUE,  'General'),
        -- Expense
        ('5000', 'Expense',                       NULL,   FALSE, 'General'),
        ('5100', 'Cost Of Sales',                 '5000', FALSE, 'General'),
        ('5110', 'Purchases',                     '5100', TRUE,  'General'),
        ('5120', 'Direct Labour',                 '5100', TRUE,  'General'),
        ('5130', 'Freight Inwards',                '5100', TRUE,  'General'),
        ('5140', 'Other Direct Costs',             '5100', TRUE,  'General'),
        ('5200', 'Operating Expense',             '5000', FALSE, 'General'),
        ('5210', 'Administrative Expenses',       '5200', TRUE,  'General'),
        ('5220', 'Selling & Distribution',        '5200', TRUE,  'General'),
        ('5230', 'IT Expenses',                   '5200', TRUE,  'General'),
        ('5240', 'HR Expenses',                   '5200', TRUE,  'General'),
        ('5250', 'Maintenance Expenses',          '5200', TRUE,  'General'),
        ('5300', 'Finance Cost',                  '5000', FALSE, 'General'),
        ('5310', 'Bank Charges',                  '5300', TRUE,  'General'),
        ('5320', 'Interest On Loan',              '5300', TRUE,  'General'),
        ('5330', 'Forex Loss',                    '5300', TRUE,  'General'),
        ('5400', 'Tax Expense',                   '5000', FALSE, 'General'),
        ('5410', 'Income Tax Expense',            '5400', TRUE,  'General'),
        ('5420', 'Turnover Tax Expense',          '5400', TRUE,  'General'),
        ('5430', 'Deferred Tax Expense',          '5400', TRUE,  'General');

    ELSE
        RAISE EXCEPTION 'UNKNOWN_ACCOUNTING_STANDARD'
            USING DETAIL = format('No Chart of Accounts template exists for accounting standard %s.', p_std);
    END IF;

    -- Single INSERT resolves parent UUIDs via self-join on temp table
    INSERT INTO rim_accounts (
        id, client_id, company_id,
        account_code, account_name,
        parent_id, posting_allowed, account_nature,
        is_system_fixed, accounting_std
    )
    SELECT
        s.new_id,
        p_client_id,
        p_company_id,
        s.code,
        s.name,
        p.new_id,   -- NULL for root nodes (no matching parent row)
        s.posting,
        s.nature,
        TRUE,
        p_std
    FROM      _seed s
    LEFT JOIN _seed p ON p.code = s.parent_code;

    UPDATE rim_accounting_setup
    SET    is_coa_seeded = TRUE
    WHERE  client_id  = p_client_id
      AND  company_id = p_company_id;

END;
$$ LANGUAGE plpgsql;
