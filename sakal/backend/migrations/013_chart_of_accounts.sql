-- ============================================================
-- 013_chart_of_accounts.sql
-- Accounting setup, financial years, unified chart of accounts
-- (groups + ledgers + customers + suppliers), and opening balances
-- ============================================================

-- ── 1. rim_accounting_setup ─────────────────────────────────
-- One row per company. Locked once is_coa_seeded = TRUE.
CREATE TABLE rim_accounting_setup (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID        NOT NULL,
    company_id       UUID        NOT NULL,
    accounting_std   TEXT        NOT NULL CHECK (accounting_std IN ('INDIAN', 'OHADA')),
    fy_start_month   INTEGER     NOT NULL CHECK (fy_start_month BETWEEN 1 AND 12),
    fy_start_day     INTEGER     NOT NULL DEFAULT 1 CHECK (fy_start_day BETWEEN 1 AND 28),
    is_coa_seeded    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID        REFERENCES rim_users(id),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       UUID        REFERENCES rim_users(id),
    UNIQUE (client_id, company_id)
);

CREATE TRIGGER trg_rim_accounting_setup_updated_at
    BEFORE UPDATE ON rim_accounting_setup
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ── 2. rim_financial_years ──────────────────────────────────
-- Each FY is always exactly 12 months. End date derived from start.
CREATE TABLE rim_financial_years (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID        NOT NULL,
    company_id       UUID        NOT NULL,
    fy_name          TEXT        NOT NULL,          -- e.g. "FY 2025-26"
    fy_start_date    DATE        NOT NULL,
    fy_end_date      DATE        NOT NULL,
    is_active        BOOLEAN     NOT NULL DEFAULT FALSE,
    is_closed        BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by       UUID        REFERENCES rim_users(id),
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by       UUID        REFERENCES rim_users(id),
    CONSTRAINT chk_fy_dates    CHECK (fy_end_date > fy_start_date),
    CONSTRAINT chk_fy_not_both CHECK (NOT (is_active AND is_closed)),
    UNIQUE (client_id, company_id, fy_start_date)
);

CREATE INDEX idx_rim_fy_company ON rim_financial_years(client_id, company_id);

CREATE TRIGGER trg_rim_financial_years_updated_at
    BEFORE UPDATE ON rim_financial_years
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ── 3. rim_accounts ─────────────────────────────────────────
-- Unified ledger master: groups, accounts, customers, suppliers.
--
-- posting_allowed = FALSE → Group node  (children allowed, no direct posting)
-- posting_allowed = TRUE  → Ledger node (no children allowed, transactions post here)
--
-- account_nature drives which screens show this account:
--   Customer  → Sales screen party picker
--   Supplier  → Purchase screen party picker
--   Cash/Bank → Payment & Receipt screen
--   General / Employee / Tax → Chart of Accounts screen
--
-- Party detail columns (phone, address, credit_limit …) are NULL
-- for non-Customer/Supplier accounts.
CREATE TABLE rim_accounts (
    -- ── Accounting structure (all rows) ──────────────────────
    id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id            UUID         NOT NULL,
    company_id           UUID         NOT NULL,
    account_code         TEXT         NOT NULL,
    account_name         TEXT         NOT NULL,
    parent_id            UUID         REFERENCES rim_accounts(id),
    posting_allowed      BOOLEAN      NOT NULL DEFAULT FALSE,
    account_nature       TEXT         NOT NULL DEFAULT 'General'
                         CHECK (account_nature IN
                             ('General','Customer','Supplier','Cash','Bank','Employee','Tax')),
    account_currency_id  UUID         REFERENCES rim_currencies(id),
    is_system_fixed      BOOLEAN      NOT NULL DEFAULT FALSE,
    accounting_std       TEXT         NOT NULL CHECK (accounting_std IN ('INDIAN','OHADA')),
    is_active            BOOLEAN      NOT NULL DEFAULT TRUE,
    is_deleted           BOOLEAN      NOT NULL DEFAULT FALSE,

    -- ── Party details (Customer / Supplier rows only) ─────────
    party_type           TEXT         CHECK (party_type IN
                             ('Individual','Company','Partnership','Government')),
    contact_person       TEXT,
    phone                TEXT,
    email                TEXT,
    address_line1        TEXT,
    address_line2        TEXT,
    city_id              UUID         REFERENCES rim_cities(id),
    country_id           UUID         REFERENCES rim_countries(id),
    tax_id               TEXT,
    party_category       TEXT,
    credit_limit         NUMERIC(15,2),
    credit_days          INTEGER      DEFAULT 30,
    is_credit_blocked    BOOLEAN      NOT NULL DEFAULT FALSE,

    -- ── Audit ─────────────────────────────────────────────────
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    created_by           UUID         REFERENCES rim_users(id),
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_by           UUID         REFERENCES rim_users(id),

    UNIQUE (client_id, company_id, account_code)
);

CREATE INDEX idx_rim_accounts_company  ON rim_accounts(client_id, company_id);
CREATE INDEX idx_rim_accounts_parent   ON rim_accounts(parent_id);
CREATE INDEX idx_rim_accounts_nature   ON rim_accounts(client_id, company_id, account_nature);
CREATE INDEX idx_rim_accounts_posting  ON rim_accounts(client_id, company_id, posting_allowed);

CREATE TRIGGER trg_rim_accounts_updated_at
    BEFORE UPDATE ON rim_accounts
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ── 4. rim_opening_balances ─────────────────────────────────
-- One row per account per financial year.
-- Only posting_allowed = TRUE accounts may have an opening balance.
CREATE TABLE rim_opening_balances (
    id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    client_id        UUID          NOT NULL,
    company_id       UUID          NOT NULL,
    account_id       UUID          NOT NULL REFERENCES rim_accounts(id),
    fy_id            UUID          NOT NULL REFERENCES rim_financial_years(id),
    ob_amount        NUMERIC(15,2) NOT NULL DEFAULT 0,
    ob_type          TEXT          NOT NULL CHECK (ob_type IN ('Dr','Cr')),
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    created_by       UUID          REFERENCES rim_users(id),
    updated_at       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_by       UUID          REFERENCES rim_users(id),
    UNIQUE (client_id, company_id, account_id, fy_id)
);

CREATE INDEX idx_rim_ob_account ON rim_opening_balances(account_id);
CREATE INDEX idx_rim_ob_fy      ON rim_opening_balances(fy_id);

CREATE TRIGGER trg_rim_opening_balances_updated_at
    BEFORE UPDATE ON rim_opening_balances
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ── 5. fn_is_accounting_ready ───────────────────────────────
-- Returns TRUE only when accounting setup is saved and CoA is seeded.
-- Call this before allowing any financial transaction.
CREATE OR REPLACE FUNCTION fn_is_accounting_ready(
    p_client_id  UUID,
    p_company_id UUID
) RETURNS BOOLEAN AS $$
    SELECT COALESCE(
        (SELECT is_coa_seeded
         FROM   rim_accounting_setup
         WHERE  client_id  = p_client_id
           AND  company_id = p_company_id),
        FALSE
    );
$$ LANGUAGE SQL STABLE;

-- ── 6. fn_next_account_code ─────────────────────────────────
-- Auto-generates next leaf account code under a parent group.
-- Formula: parent_code + zero-padded 3-digit sequence (001, 002 …)
-- Used when creating Customer / Supplier / Bank / Cash accounts.
CREATE OR REPLACE FUNCTION fn_next_account_code(
    p_client_id  UUID,
    p_company_id UUID,
    p_parent_id  UUID
) RETURNS TEXT AS $$
DECLARE
    v_parent_code TEXT;
    v_max_suffix  INTEGER;
BEGIN
    SELECT account_code INTO v_parent_code
    FROM   rim_accounts
    WHERE  id = p_parent_id;

    SELECT COALESCE(MAX(RIGHT(account_code, 3)::INTEGER), 0)
    INTO   v_max_suffix
    FROM   rim_accounts
    WHERE  client_id  = p_client_id
      AND  company_id = p_company_id
      AND  parent_id  = p_parent_id
      AND  is_deleted = FALSE;

    RETURN v_parent_code || LPAD((v_max_suffix + 1)::TEXT, 3, '0');
END;
$$ LANGUAGE plpgsql STABLE;

-- ── 7. fn_seed_chart_of_accounts ────────────────────────────
-- Seeds the full Chart of Accounts for a company on first setup.
-- Only Fixed accounts are seeded (no Template, no User rows).
-- Called once from the Accounting Setup screen on Save.
CREATE OR REPLACE FUNCTION fn_seed_chart_of_accounts(
    p_client_id  UUID,
    p_company_id UUID,
    p_std        TEXT
) RETURNS VOID AS $$
BEGIN
    -- Temp table pre-assigns UUIDs so self-referential parent_id
    -- can be resolved in a single INSERT (no two-pass needed).
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
