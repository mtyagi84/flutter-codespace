Status: Implemented 2026-08-28 (migrations 169-173, not yet run by user).

# Master Data Printing Reports — 13 reports, first reports this category has ever had

## Context
No Master screen anywhere in the app has a Print or Export button today — confirmed by direct code
search (grep across `lib/features/master/` for Print/Export/PDF/Excel found nothing relevant). This is a
genuinely greenfield feature. Full design (context, schema facts, per-report filters/columns, explicit
"deliberately not building" list) was reviewed with the user as an HTML artifact before any SQL was
written: `sakal/docs/screens/artifact_master_data_reports_plan.html`. This doc is the plan-approval
record — read the artifact for the complete per-report spec.

## Key finding — reuses the existing reporting engine, zero new Flutter code
Every report registered in `ric_report_definitions` (TABULAR, MATRIX, or HIERARCHICAL) automatically gets
a working, letterheaded PDF export and an Excel export via `lib/core/reporting/report_pdf_export.dart` /
`report_excel_export.dart` — confirmed by direct code read. "Master Data Printing" is therefore purely a
migration/registry exercise, identical in shape to the Purchase (158-162) / Sales (163-165) / Finance
(166-168) report batches already built this session.

## Design decision — trees are Tabular with computed indent, not Hierarchical
Chart of Accounts, Chart of Groups, and Item Categories are all self-referencing trees, but the existing
HIERARCHICAL report type/renderer (`PlNode`/`sakal_report_hierarchical_table.dart`) is hardcoded to a
single monetary `amount` column per row — built for P&L/Balance Sheet, not a pure structural list with
nothing to sum. All three are instead built as TABULAR reports with a computed
`repeat('  ', level_depth) || name` indent column — simpler, no new widget work, prints cleanly.

## Menu placement
One new `group_code = 'MST-RPT'` ("Master Reports"), registered under the SAME shared `AD` (Admin/Setup)
system module every other Master screen already uses (confirmed via `fn_seed_client_modules.sql`:
Customer/Supplier/Product/Chart of Accounts/Tax Master etc. are all under `AD`, just split into
`SL-MST`/`PR-MST`/`IN-MST`/`FN-MST` group_codes for sidebar sectioning) — consistent with the existing
convention, not a new module_code.

## The 13 reports
1. Item/Product Master Report
2. Customer Master Report
3. Supplier Master Report
4. Chart of Accounts Report (postable ledger accounts, indented)
5. Chart of Groups Report (non-posting group nodes, indented)
6. Item Category Master Report (tree, indented)
7. Common Masters Report (Brand/UOM/Size/Color etc., one report grouped by type)
8. Tax Master Report
9. Tax Group Master Report (group + member taxes)
10. Payment Terms Master Report
11. Sales Executives Master Report
12. Additional Charges Master Report
13. Price List Report (batch register — Entry grouped, Line detail; a future "resolved effective price"
    variant is a v2 candidate, not built here)

## As-built: the 13 reports, by migration
- **169** (core catalog/party): Item/Product Master Report (`PRODUCT_MASTER_REPORT`), Customer Master
  Report (`CUSTOMER_MASTER_REPORT`), Supplier Master Report (`SUPPLIER_MASTER_REPORT`) — the latter two
  share one view (`v_party_master_report`), filtered by `account_nature` at the registry level, same
  "share a view, register twice" pattern used for GRN/Purchase Return earlier in this session.
- **170** (indented trees): Chart of Accounts Report / Chart of Groups Report (`v_chart_of_accounts_tree`,
  one shared recursive-CTE view over `rim_accounts`, split by `posting_allowed` at the registry/function
  level), Item Category Master Report (`v_item_category_tree`, its own recursive CTE over
  `rim_item_categories`). All three use `repeat('   ', level_depth) || name` for the indented display
  column, per the TABULAR-not-HIERARCHICAL design decision.
- **171** (reference/tax): Common Masters Report (`COMMON_MASTERS_REPORT`, grouped by type), Tax Master
  Report (`TAX_MASTER_REPORT`, resolves each tax's CURRENTLY effective rate from `rim_tax_rates` via a
  correlated subquery — rates are versioned by `effective_from`/`effective_to`), Tax Group Master Report
  (`TAX_GROUP_MASTER_REPORT`, grouped by group, detail = member taxes with their own current rate).
- **172** (small reference masters): Payment Terms Master Report (`PAYMENT_TERMS_MASTER_REPORT`, grouped
  by term — header's own `description` column already has the printable summary text, so the group row
  needs no synthesis; detail rows expose the raw installment lines for completeness), Sales Executives
  Master Report (`SALES_EXECUTIVES_MASTER_REPORT`), Additional Charges Master Report
  (`ADDITIONAL_CHARGES_MASTER_REPORT`).
- **173** (pricing): Price List Report (`PRICE_LIST_REPORT`, grouped by Price Master entry/batch — the v1
  "batch register" scope from the artifact, not a resolved as-of-date effective price list).

## Real schema corrections made mid-build (caught by direct read, not assumed)
- `rim_item_categories` has NO `category_code` column — only `category_name`/`category_short`. The Item
  Category report's "Short Code" column reads `category_short`, not a code column that doesn't exist.
- `rim_payment_terms.description` already IS the printable summary text ("30% Advance, 70% in 30 Days")
  — admin-typed, not synthesized from the lines. The report surfaces it directly at the group level
  rather than re-deriving it from `rim_payment_term_lines`.
- `rim_taxes` has no direct `rate` column — rates live in a separate, date-versioned `rim_tax_rates`
  table (`effective_from`/`effective_to`, multiple `rate_label`s like STANDARD/REDUCED/ZERO). The Tax
  Master and Tax Group reports both resolve "current rate" via a correlated subquery matching
  `CURRENT_DATE` against the effective window — same convention this schema already uses elsewhere for
  rate resolution (`fn_get_active_tax_rate`).

## Menu placement note
No `ric_user_location_access` scoping appears anywhere in this batch's views — confirmed as a deliberate
omission, not an oversight: Master data (`rim_products`, `rim_accounts`, tax/common masters, etc.) is
company-wide, not location-scoped, unlike every Purchase/Sales/Finance/Inventory transactional report
built earlier this session.

## Deliberately not built
Location/Location Group Master Report (skipped per explicit user decision — low print value), Account
Link Setup, Opening Balance Report, Users/Permissions — see artifact for the full reasoning per item.

## Verification (once migrations run)
1. All 13 reports appear under the new "Master Reports" menu group for a user with existing Master
   module access.
2. PDF export on at least one Tabular report (e.g. Item Master) and one Grouped report (e.g. Tax Group
   Master) — confirm letterhead, filters-applied summary, and grouped rows render correctly.
3. Chart of Accounts / Chart of Groups / Item Categories: confirm indentation correctly reflects the real
   parent/child depth for a multi-level account or category.
4. `flutter analyze`/`flutter test` — no Flutter changes expected for this batch, but worth a green-check
   pass regardless.
