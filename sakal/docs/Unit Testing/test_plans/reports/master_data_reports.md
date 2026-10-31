# Master Data Reports — Test Plan
Module: AD — Settings | Group: Master Reports | See `00_INDEX.md` for the Cross-Cutting Checklist ("CCC #N").

Report template: **Load with no filters (smoke) / Every filter individually / Data
accuracy vs. the master screen / Export & Print / Permission-denied / CCC**.
These 13 reports are all print/export-oriented snapshots of master data (built
2026-08-28, zero new Flutter code, shared `ReportScreen` engine) — lighter test
depth than transaction-derived reports since there's no GL/stock correctness to
verify, mainly "does it match the master screen exactly."

---
All 13 reports smoke-tested `2026-10-31` via `e2e/test_mstrpt_smoke.js` — every one loads with zero HTTP errors. Individual findings below.

## MST-RPT-PRD — Item/Product Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRDR-01 | Matches Product Master screen | Create/edit a product, run the report | New/changed product appears with matching field values | High | Passed | E2E `2026-10-31`: loaded with no filters, showed exactly 2 rows (`PRD-00001`/`PRD-00002`), DB-verified `SELECT count(*) FROM rim_products WHERE is_active=true AND is_deleted=false` for this tenant = 2, exact match. Columns (Product Code/Name/Category/Brand/UOM/Tracking Type/Sales+Purchase Tax Group/HSN-SAC/Main Supplier) all present. |
| PRDR-02 | Filter by category/brand | Apply a filter | Only matching products show | Med | Not Started | Filters are present (Category/Brand/Tracking Type/Product Nature/Active Only) but not individually exercised this pass — both test products have no category/brand assigned, so a meaningful filter test needs richer fixture data. |
| PRDR-03 | Export to Excel/PDF | Export | File opens correctly, data matches | Med | Not Started | PDF/Excel export icons are visible (top-right) but not clicked this pass. |

## MST-RPT-CUS / MST-RPT-SUP — Customer / Supplier Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PARTYR-01 | Matches Customer/Supplier Master | Create/edit a party, run the report | Matches exactly | High | Passed (bug found + fixed) | E2E `2026-10-31`: **real bug found** — both reports initially showed an extra row for the party GROUP header itself (Customer Master Report showed `4110 — Customers` with every detail column blank, alongside the one real test customer; Supplier Master Report showed `4010 — Suppliers` the same way). Root cause confirmed: `v_party_master_report` (migration 169) filters only `account_nature IN ('Customer','Supplier')` and `is_deleted=false` — never excludes non-posting (group/header) accounts, which share the same `account_nature` as their postable children. **Fixed in migration 236**: added `AND a.posting_allowed = true` to the view's WHERE clause (re-stated `security_invoker=true` explicitly per project convention), deployed directly to dev DB and re-verified both server-side (`SELECT * FROM v_customer_master_report`/`v_supplier_master_report` now return exactly 1 row each, the real party) and live in the browser (both reports now show only the real customer/supplier, Ledger Currency correctly shown as USD for the customer). `MST-RPT-COAR-GRP`-GRP (below) was checked for the same class of bug but found to be an intentional "two views of one tree" design, not a defect — see its own note. |
| PARTYR-02 | Ledger currency shown (CCC #2) | Run for parties with different ledger currencies | Currency indicated per party | Med | Passed | Confirmed in the same screenshot above — the one test customer's `LEDGER CURRENCY` column correctly shows `USD`. Only one currency tested (no second-currency customer in this fixture) — multi-currency comparison not separately exercised. |

## MST-RPT-COA / MST-RPT-GRP — Chart of Accounts / Chart of Groups Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| COAR-01 | Tree structure matches COA screen | Run for OHADA, INDIAN, and ZAMBIA companies | Indented TABULAR tree matches each standard's real structure | High | Passed (partial) | E2E `2026-10-31`: Chart of Accounts Report loads correctly for this tenant's OHADA standard — ascending Account Code order, Parent Group column shows the correct hierarchy text (e.g. "Class 1 - Equity & Long Term Financing" → "Reserves"), Account Nature/Accounting Std/Active columns all populated correctly. Only OHADA tested this pass (this tenant's own standard) — INDIAN/ZAMBIA not independently re-verified. **Observation, not a confirmed bug**: `CHART_OF_GROUPS_REPORT` and `CHART_OF_ACCOUNTS_REPORT` both read the exact same `v_chart_of_accounts_tree` view with no distinguishing filter (confirmed via `ric_report_definitions` — both rows list `source_object='v_chart_of_accounts_tree'`), so "Chart of Groups Report" shows every account including postable leaves (e.g. `3600001 Stock Account`), not just group/header rows. This reads like it could be the same class of defect PARTYR-01 just fixed (two report_keys sharing one unscoped view) — BUT unlike the Customer/Supplier case, there's no blank-detail-row smoking gun here (COA genuinely needs to show every account in its tree), and it may be a deliberate "same tree, different column emphasis" design (COA emphasizes Nature/Std/Active; Groups emphasizes Parent/Level) rather than a "groups only" promise. Flagged for the user to confirm intent before any fix — not changed this pass. |
| COAR-02 | New leaf accounts show (2026-09-13 fix) | On a fresh tenant, run after Accounting Setup | Auto-created Stock/COGS/Purchase Accrual leaves appear | Med | Passed | Confirmed in the same screenshot — `3600001 Stock Account` (an auto-seeded leaf under Merchandise) appears correctly in the tree. |

## MST-RPT-ITC — Item Category Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| ITCR-01 | Tree + flags match Item Categories screen | Create nested categories with flags, run report | Matches exactly | Med | Passed | E2E `2026-10-31`: showed both known categories ("General", "QA Category 41856") at Level 1, matching expected state. Nested/multi-level category structure with flags not separately exercised (both test categories are flat, top-level). |

## MST-RPT-CMN — Common Masters Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CMNR-01 | New-tenant starter values appear (2026-09-13 fix) | Fresh tenant, run report | UOM/Brand/Color/reason/category defaults all show | Med | Passed | E2E `2026-10-31`: all 10 expected types grouped correctly (Brand/Color/Consumption Area/Customer Category/Department/Incoterm/Purchase Return Reason/Stock Adjustment Reason/Supplier Category/Unit), collapsed by default with expand/collapse-all controls. Expanded "Brand" — shows "Generic" value nested correctly (Sort Order 1.00, Active). |

## MST-RPT-TAX / MST-RPT-TXG — Tax Master / Tax Group Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| TAXR-01 | New default tax setup appears (2026-09-13, OHADA/ZAMBIA) | Fresh OHADA/ZAMBIA tenant | 16%/0% default tax + group show correctly | High | Passed | E2E `2026-10-31`: Tax Master Report shows `VAT_STD` (TVA Standard 16%, rate=16.00) and `VAT_ZERO` (TVA Exonere/Export 0%, rate=0.00) correctly, both with Output/Input GL accounts resolved ("State & Taxes"/"QA Input VAT Receivable"). Tax Group Master Report shows the matching `VAT_STD_GRP`/`VAT_ZERO_GRP` groups. Several test-created tax codes show "—" for Current Rate % (no effective rate row yet configured) — expected behavior for those specific test fixtures, not a defect in the default OHADA seed. |
| TAXR-02 | Rate history shown correctly | A tax with 2+ date-effective rates | Both rates listed with their effective dates | Med | Not Started | No test tax in this tenant has 2+ date-effective rate rows — needs dedicated fixture data to exercise. |

## MST-RPT-PYT — Payment Terms Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PYTR-01 | Matches Payment Terms screen | Create a term, run report | Matches, including installment lines | Med | Passed | E2E `2026-10-31`: shows both existing test terms (`QAT34039`, `QAT79491`) correctly as collapsible rows (installment lines nest underneath, matching the Common Masters report's own expand/collapse pattern). |

## MST-RPT-SEX — Sales Executives Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| SEXR-01 | Matches Sales Executives screen | Create an executive, run report | Matches | Low | Passed | E2E `2026-10-31`: shows `QASE02`/"QA Test Sales Exec 2" with correct phone/email/Active status, exactly matching the record created earlier this session in SL-EXE's own EXE-01 test. |

## MST-RPT-CHG — Additional Charges Master Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| CHGR-01 | ADD vs DEDUCT nature shown correctly | Create both types, run report | Nature clearly distinguished | Med | Passed | E2E `2026-10-31`: shows `QAF83686` (Freight, nature=ADD) and `QAR83686` (Rebate, nature=DEDUCT), both clearly labeled via distinct badges in the NATURE column. |

## MST-RPT-PRC — Price List Report
| ID | Scenario | Steps | Expected Result | Priority | Status | Bug Ref |
|---|---|---|---|---|---|---|
| PRCR-01 | Matches Price Master, currency shown (CCC #2) | Create prices in 2+ currencies, run report | Each price shows its own currency correctly | High | Passed (partial) | E2E `2026-10-31`: this report requires explicit "Run Report" (engine-wide `auto_load` gate) rather than loading automatically — confirmed the button fires cleanly with zero HTTP errors, correct column headers (Entry No/Date/Effective Date/Price Type/Customer/Location/Status/Item Code/Name/Unit) render even with zero matching rows (the earlier Price Master test batch from SL-PRC's own PRC-01 test had already been deleted as part of that test's cleanup, so an empty result here is expected, not a defect). A live create→approve→report round trip (without deleting the batch first) was not re-exercised — would be a good follow-up to directly confirm a real row renders with correct currency. |
