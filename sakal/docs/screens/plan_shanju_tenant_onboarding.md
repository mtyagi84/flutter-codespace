# Shanju Investment Limited — Real Tenant Onboarding Plan

Status: Data prep complete 2026-09-18/19, onboarding execution pending
(the user's own turn — Track D's runbook, see `Shanju_Onboarding_Runbook.md`
under `sakal/docs/Tenant/`). Track A's original scope (simple bulk-upload
buttons on Chart of Accounts + Product Master) was superseded the next day
by a more complete, dedicated screen — see `plan_bulk_upload_products.md`
for what actually shipped for the Product side; Track A's Chart of
Accounts half is unchanged and still live as originally built here.

## Context

The app has its first real tenant: **Shanju Investment Limited**, a
steel/hardware trading company in Lusaka, Zambia. The user wants this tenant
onboarded through the REAL app — registration wizard, Chart of Accounts,
Product Master, etc. — exactly as a Data Operator would in production, not
via the backend-RPC test shortcuts used for QA. The user supplied
`sakal/docs/Tenant/Shanju data Template.xlsx` (a real Tally export) and asked
me to read every sheet and plan the onboarding.

**What changed the scope of this plan**: while sizing the manual-entry
effort, I found that only 2 screens in the whole app support bulk Excel
upload today (Opening Stock, Opening Balance) — Chart of Accounts and
Product Master both require one-row-at-a-time entry. Given this tenant needs
147 new ledger accounts and 487 products, the user chose to **build
bulk-upload for the Chart of Accounts and Product Master screens first**,
before starting the actual onboarding — a one-time investment that pays off
for every future tenant, not just this one.

## Data inventory (from the 5-sheet Excel file)

| Sheet | Rows | Content |
|---|---|---|
| Company | 7 | "SHANJU INVESTMENT LIMITED", Lusaka, Zambia — single address block |
| Users | 4 | 3 real users: Nitin (Admin), Anjali (Data Operator), Jay (Data Operator) — no emails/phones given |
| StoreShop | 2 | 1 location: "Steel-Lumumba", type Warehouse |
| Accounts | 148 | Tally-style COA export — 41 Customer ledgers, 26 Supplier ledgers, 80 other GL leaf accounts (Cash/Bank/Capital/Depreciation/Expense/Purchase&Sales-category accounts), 1 row to exclude (Tally's own "Profit & Loss A/c" rollup) |
| Product | 487 | Steel/hardware inventory items — Group+SubGroup (2-level category), Unit, Initial Cost, Opening Stock qty, all in ZMW |

## Confirmed decisions (from this session's clarifying questions)

1. **Currency at registration**: Base Currency = **ZMW**, Local Currency = **USD**.
2. **Every amount in the Accounts sheet is already in ZMW**, regardless of
   whether the account's own Tally group is suffixed `-USD` or `-ZMW`. For a
   `-USD`-suffixed account, the real USD ledger-currency amount = the sheet's
   ZMW figure **÷ 19.66** (the confirmed rate). A `-ZMW`-suffixed or
   unsuffixed account's ledger currency is ZMW, amount used as-is.
3. **Build bulk Excel-upload for the ONE generic Chart of Accounts screen
   only, plus Product Master** — NOT separate Customer Master / Supplier
   Master uploads. User's correction: the Accounts sheet already mixes every
   nature (general ledgers, customers, suppliers, expense, income) in one
   list, so one upload mechanism on Chart of Accounts (which already
   supports every `account_nature` including Customer/Supplier + their party
   fields) covers all 147 accounts in a single feature. Customer/Supplier
   Master's own dedicated bulk-upload is explicitly deferred — build later
   only if actually needed.
4. **Deliverable**: a cleaned staging Excel (mapped to the new upload
   templates' exact columns, all data-quality issues resolved/fixed per the
   rules below) + a written step-by-step runbook, both saved under
   `sakal/docs/Tenant/`.
5. **Registration is ALREADY DONE** — the user registered the tenant through
   the real wizard before this plan was finalized. Confirmed to match this
   plan's assumptions exactly: Base=ZMW, Local=USD, Accounting Std=ZAMBIA.
   Track D's runbook below starts from step 2 (Users), not step 1.

## Data-quality issues found in the source file — resolutions (confirmed by user)

1. **3 products have NEGATIVE opening stock** ("Miscellaneous Items" -4 Pcs,
   "Self Tapping Screws 3\"x8mm" -200 Pcs, "Steel Items" -2 Pcs) — **clamp to
   0** in the staging file. No tenant confirmation needed.
2. **"Purchase of Lipped Channel" is tagged group "Sales Accounts"** in the
   source (row 88, Accounts sheet) — a data-entry error in the client's own
   Tally file. **Fix**: map it to the Purchase side (5110 Purchases) instead.
3. **Duplicate/typo category group names** in Product sheet: "Angles &
   Deformed Bars" (29 rows) vs "Angles & Deformed Bars & Deformed Bars" (12
   rows); "Fencing Items" (20 rows) vs "fencing Items" (1 row, case-only).
   **Fix**: merge into one canonical name each during cleanup. **Also**:
   every name-based lookup the new Product Master upload performs (Category,
   Sub-Category, Unit) must normalize both sides with `.trim().toUpperCase()`
   before comparing — a general robustness fix for the upload feature itself
   (Track A), not just a one-time data-cleaning step, so future uploads
   don't silently fail on stray whitespace/case differences either.
4. **The Product sheet's "Brand" column actually contains the Initial Cost
   figure repeated**, not real brand names. **Fix**: create one Common
   Master entry (type BRAND, description "N/A") during setup (Track D step
   3), and assign every product to that single "N/A" Brand — ignore every
   numeric value found in the source Brand column entirely.
5. **Supplier column (→ `rim_products.main_supplier_id`, a FK to
   `rim_accounts`) is 100% empty** — a FK can't literally store the text
   "N/A"; since there is no real supplier reference in the source data
   anyway, leave `main_supplier_id` NULL for every product (the correct
   equivalent of "not set", no placeholder account needed).
6. **"Item Type (Import/Local)" has no corresponding column anywhere in
   `rim_products`** (confirmed via the migration — no `item_type`/
   `import_local` field exists in the schema at all). This column will not
   be imported; nothing to configure.
7. **One Unit value is a Tally encoding artifact**: `_x0004_ Not Applicable`
   on "Measuring Tape 5 Mtrs" — **fix**: set to `Pcs`.
8. **2 "Current Assets" accounts look like misclassified party names**
   ("CHI STEEL (Z) LTD", "Shree Ganesh" — both have NO stated opening
   balance in the source, so no balance is at risk either way). **Fix per
   standard accounting classification**: map both to 1160 "Other Current
   Assets" (the standard catch-all for an unclear current-asset-like line
   with no further detail) rather than guessing Customer vs Supplier. (The
   2 "Advance to <person>" rows in the same Tally group ARE genuine staff
   advances, correctly mapped to 1150 Advances & Prepayments — not part of
   this issue.)
9. **"Profit & Loss A/c" (Tally group `_x0004_ Primary`)** — Tally's own
   built-in retained-earnings rollup. **Confirmed: EXCLUDE** from import;
   its balance (1,137,189.12 Cr) becomes the reconciliation check against
   Trial Balance after all other opening balances are entered.
10. **"Suspense Account" and "Rounding Off"** are genuine Tally accounts with
    real balances/usage — import as ordinary GL leaf accounts under Current
    Liabilities / Indirect Expenses respectively, not excluded.
11. **The Zambia COA template (migration 180) is missing 3 lines** this
    tenant's data needs: Depreciation Expense, Accumulated Depreciation
    (contra-asset), and a generic "Office Equipment" fixed-asset category.
    **Confirmed: add these as permanent additions to the SHARED
    `fn_seed_chart_of_accounts` ZAMBIA branch** (a new migration, additive
    only — 3 new `_seed` rows, OHADA/INDIAN branches untouched), so every
    future Zambia tenant gets them too. Proposed codes (siblings of the
    existing ZAMBIA leaves): `1245` "Office Equipment" (posting, General,
    under `1200`), `1295` "Accumulated Depreciation" (posting, General,
    under `1200`), `5260` "Depreciation Expense" (posting, General, under
    `5200`). Since Shanju's own Chart of Accounts was ALREADY seeded before
    this migration will exist (`fn_seed_chart_of_accounts` only runs once,
    at accounting-setup time, gated by `is_coa_seeded`), these 3 lines still
    need a one-time manual add to Shanju's own COA via the Chart of Accounts
    screen after the migration ships — small, 3 rows, no bulk upload needed
    for these.

## Track A — Build bulk Excel-upload (Chart of Accounts + Product Master only)

Follow the EXACT existing pattern from `opening_balance_entry_screen.dart`
and `opening_stock_entry_screen.dart` (both fully documented via this
session's exploration — see the two Explore-agent findings for exact line
numbers) on just these 2 screens:
- `lib/features/master/presentation/screens/chart_of_accounts_screen.dart` — one upload covers ALL 147 accounts (general ledgers + Customer + Supplier + Cash/Bank), since this screen already supports every `account_nature` including the party-detail fields Customer/Supplier need. Customer Master/Supplier Master's own dedicated bulk-upload is explicitly OUT of scope for now (build later only if actually needed).
- `lib/features/master/presentation/screens/product_entry_screen.dart` (or its list screen, whichever hosts the bulk action — Opening Stock/Balance both put it on the entry/worksheet screen, but Product's "worksheet" IS effectively the list screen since there's no multi-row grid entry screen for products; needs a design call during implementation — probably a new bulk-import affordance on `product_list_screen.dart` that creates multiple new DRAFT-equivalent rows in one action, since Product Master has no header+lines shape to copy from)

**Shared building blocks to reuse, not reinvent**:
- `package:excel` (`xls.Excel.decodeBytes`/`createExcel`) + `package:file_picker` + `core/reporting/web_download.dart`'s `downloadBytesOnWeb()` — identical on both screens.
- Header-name-driven column matching (`col('account code')` style helper) — never positional.
- Match-by-code semantics: for Chart of Accounts, match by **Parent Account Code** (to resolve `parent_id`) since these are NEW accounts being created, not updates to existing ones — different from Opening Balance's "match existing account by code" since here the target rows don't exist yet. For Product Master, no parent-lookup needed — brand-new `product_code`s are simply generated in sequence, matching the existing `_generateCode()` counter logic (`products_remote_ds.dart:81-97`) run N times instead of once.
- Deferred validation (accept the row, flag business-rule problems at Save, same as Opening Balance) rather than Opening Stock's stricter upload-time validation — creating master data has fewer invariants to check than a stock/GL transaction.
- Category/UOM/Tax-Group lookups during Product upload: by exact name match against ALREADY-EXISTING `rim_item_categories`/`rim_common_masters` rows (created manually first, see Track D), **normalized via `.trim().toUpperCase()` on both sides before comparing** (issue #3) — unknown name after normalizing = skipped row + error, same convention as every existing upload.
- Chart of Accounts upload includes the Customer/Supplier party-detail columns (Phone, Email, Address, Credit Days/Limit, etc.) as optional trailing columns, populated only when `Nature = Customer` or `Supplier` — reuses the exact fields already on that screen's own party-details block, nothing new to design there.

**Permission wiring** (mechanical, same recipe as migrations 077/133):
1. New migration: `ric_master_menus.excel_upload_allowed = true` for feature codes `MST-COA`, `MST-PRD`.
2. Backfill `ric_user_menus.excel_upload_allowed` for existing users (same `INSERT ... ON CONFLICT DO UPDATE` shape as migration 109's `FN-PRV` backfill).
3. Update `fn_seed_client_modules.sql` so future clients get this by default.

**Account-Code generation for bulk-created accounts**: Chart of Accounts
today calls RPC `fn_next_account_code(p_client_id, p_company_id, p_parent_id)`
once per single-row Add. For bulk upload, the cleanest option (avoiding N
sequential RPC round-trips) is to let the staging Excel **specify the
intended Account Code directly** (since this plan's own data-prep step
already computes clean codes for all 147 accounts against the real Zambia
COA parent structure) — the upload's Save step then does a plain sequential
`fn_next_account_code`-free insert using the pre-assigned code, with a
uniqueness check against the existing table before Save (same spirit as the
existing `(client_id, company_id, account_code)` UNIQUE constraint already
enforcing this server-side as a safety net either way).

## Track B — Tally Group → Zambia COA parent mapping

Full account_code parent for every leaf, computed from the real
`fn_seed_chart_of_accounts` ZAMBIA branch (migration 180):

| Tally Account Group | → SAKAL parent (code) | Nature | Notes |
|---|---|---|---|
| Sundry Debtors* | 1120 Trade Receivables | Customer | via Chart of Accounts, one upload covers all natures |
| Sundry Creditors* | 2110 Trade Payables | Supplier | via Chart of Accounts, same upload |
| Cash-in-Hand | 1110 Cash & Bank | Cash | 2 leaves: Cash USD, Cash-ZMW |
| Bank Accounts | 1110 Cash & Bank | Bank | 2 leaves: IZB USD, IZB ZMW |
| Capital Account | 3120 Proprietor/Partner Capital | General | NITIN SHARMA |
| Current Assets (staff advances) | 1150 Advances & Prepayments | General | "Advance to X" rows only |
| Current Assets (CHI STEEL/Shree Ganesh) | 1160 Other Current Assets | General | fixed per issue #8 — no balance at stake |
| Duties & Taxes: NAPSA/PAYE Payable | 2130 PAYE & NAPSA Payable | Tax | |
| Duties & Taxes: NHIMA Payable | 2130 PAYE & NAPSA Payable (co-located) | Tax | Zambia COA has no separate NHIMA line; grouping with PAYE/NAPSA is the closest fit |
| Duties & Taxes: Value Added Tax | 2120 VAT Payable | Tax | |
| Duties & Taxes: Withholding Tax Receivable | 1160 Other Current Assets | Tax | distinct from VAT Recoverable (1140) |
| Vehicles | 1250 Motor Vehicles | General | 2 leaves |
| Furniture & Fixtures | 1240 Furniture & Fittings | General | 1 leaf: Office Cabin |
| Office Equipment (assets) | 1245 Office Equipment (NEW seeded line) | General | Branding Material, Canopy — see issue #11 |
| Depriciation (accumulated) | 1295 Accumulated Depreciation (NEW seeded line) | General | contra-asset, see issue #11 — all 3 source rows map to this one line |
| Current Liabilities (Salary & Wages Payable) | 2170 Other Current Liabilities | General | |
| Provisions | 2140 Accrued Expenses | General | |
| Direct Expenses | 5100 Cost Of Sales → 5120/5140 | General | Salary→5120, Warehouse Rent→5140 |
| Indirect Expenses (26 rows) | 5200 Operating Expense tree | General | mostly 5210 Administrative; Bank Charges→5310; Realized/Unrealized Gain-Loss→5330 Forex Loss (Zambia COA has no symmetric Forex Gain line — use 4200 Non Operating Revenue's Interest Income sibling area if a gain-side account is ever needed, or add one custom leaf); Depreciation Expense x3 → 5260 Depreciation Expense (NEW seeded line, issue #11) |
| Indirect Incomes | 4200 Non Operating Revenue | General | CUTTING CHARGES, Interest Received |
| Purchase Accounts + Purchase of * (13 rows) | 5110 Purchases | General | one leaf per product category |
| Sales Accounts (12 rows, incl. reclassified Lipped Channel) | 4110 Product Sales | General | one leaf per product category |
| _x0004_ Primary (Profit & Loss A/c) | **EXCLUDED**, see issue #9 | — | — |

## Track B correction (found while building the staging file)

The original Track B table above mapped several rows directly onto SEEDED
LEAF accounts (e.g. `3120`, `2120`, `1240`, `2170`, `2140`, `5120`, `5140`,
`5310`, and — worse — `1245`/`1295`/`5260`, the very lines just added in
migration 189) as if they were parent GROUPS. A posting leaf can never have
children in this schema. Corrected split, verified programmatically against
the live migration 189 seed data:
- **138 rows → NEW child accounts** under a real GROUP ancestor (`1100`,
  `1110`, `1120`, `1200`, `2100`, `2110`, `4100`, `4200`, `5100`, `5200`,
  `5300` — all confirmed `posting_allowed=false`). This includes the
  Accumulated Depreciation (3), Office Equipment (2), Depreciation Expense
  (3), and NAPSA/NHIMA/PAYE (3) rows that originally, incorrectly, pointed
  at the single new seeded leaves themselves.
- **8 rows → REUSE an existing seeded leaf directly**, no new account
  created at all (Capital Account → `3120`, VAT → `2120`, Office Cabin →
  `1240`, Salary & Wages Payable → `2170`, Provisions → `2140`, Direct
  Labour → `5120`, Warehouse Rent → `5140`, Bank Charges → `5310`) — each
  is the ONLY source row needing that exact concept, so it just posts its
  opening balance against the account the seed already created.
- **1 row excluded** (Profit & Loss A/c).
- Total: 138 + 8 + 1 = 147, reconciling exactly against the source file's
  147 data rows (the original plan said "148" — an off-by-one that counted
  the header row; corrected here).

`Shanju_Staging.xlsx`'s **Accounts** tab now holds only the 138 NEW rows;
a separate **Reuse Existing Accounts** tab holds the 8 REUSE rows with the
existing account code to post against directly in Opening Balance Entry.

## Track C — Data prep deliverable

Produce `sakal/docs/Tenant/Shanju_Staging.xlsx` with one tab per upload
target, columns matching exactly what Track A's templates will expect once
built:
- **Accounts tab** (single tab, ONE upload covers every nature per the
  corrected Track A scope): all 147 non-excluded accounts — Parent Account
  Code (from the Track B table), Account Name, Nature (General/Customer/
  Supplier/Cash/Bank/Tax), Currency, Opening Balance (Dr/Cr + amount, in the
  account's own ledger currency — pre-converted using the ÷19.66 rule for
  USD accounts, for later entry via Opening Balance Entry's own EXISTING
  bulk-upload), plus Customer/Supplier party-detail columns left blank
  (none of that data exists in the source).
- **Products tab**: 487 rows, negative opening-stock quantities clamped to 0
  (issue #1), cleaned Category/Sub-Category (merged duplicates per issue
  #3, normalized), Unit cleaned (issue #7), Initial Cost, Opening Stock Qty,
  Brand set to the literal value "N/A" for every row (issue #4), Supplier
  left blank/null (issue #5).
- **Flagged Issues tab**: a record of every data-quality issue found and how
  it was resolved (for audit/reference — all issues are now resolved per
  the decisions above, none remain blocking).

## Track D — Actual onboarding execution runbook

**Step 1 (Registration) is ALREADY DONE** — completed by the user via the
real wizard before this plan was finalized; confirmed to match Base=ZMW/
Local=USD/Accounting Std=ZAMBIA. Runbook continues from step 2:

2. **Create the 2 additional users** (Anjali, Jay — Data Operator role) via User Management — real emails/phones still needed from the tenant, not in the source file.
3. **Create the "N/A" Brand entry** via Common Masters (type BRAND) — needed before the Product upload so every product's Brand can resolve to it (issue #4).
4. **Create the 6 UOM entries** (Box, Kgs, Pcs, Pkts, Roll, mtrs) via Common Masters — trivial, one-by-one.
5. **Create the Item Category tree** (~18 top-level groups + their sub-groups, cleaned per issue #3) via the Item Categories screen — one-by-one, small enough not to need bulk upload.
6. **Deploy the new migration** adding the 3 seeded Zambia COA lines (issue #11: Office Equipment 1245, Accumulated Depreciation 1295, Depreciation Expense 5260) — benefits all future Zambia tenants; since Shanju's own COA was already seeded before this migration exists, also manually add these same 3 lines to Shanju's live COA via the Chart of Accounts screen (one-by-one, small number).
7. **Bulk-upload all 147 accounts** (general + Customer + Supplier + Cash/Bank/Tax, all in one file) via Chart of Accounts' new Excel upload.
8. **Bulk-upload the 487 products** via Product Master's new Excel upload.
9. **Bulk-upload Opening Balances** for all 147 accounts via the EXISTING Opening Balance Entry screen (no new build needed here).
10. **Bulk-upload Opening Stock** for the products with real quantities via the EXISTING Opening Stock screen (no new build needed here).
11. **Verify**: run Trial Balance, confirm it balances to zero and that the sum matches Tally's own reported figures (cross-checked against the excluded "Profit & Loss A/c" balance from issue #9 as the reconciling number).

## Open items still needing the tenant's (Nitin's) input
- Real email/phone for Anjali and Jay (not in the source file, needed for user creation) — the only remaining item that can't be resolved from the data alone. Every other data-quality issue found this session has a confirmed resolution (see the numbered list above) and needs no further tenant confirmation.

## Implementation note (2026-09-19)
Track D's numbered steps above reflect this plan's ORIGINAL shape.
`plan_bulk_upload_products.md` (built the next day) replaced the simple
Product Master upload button with a dedicated screen that auto-creates
Category/Item Size/Item Color/Brand/Unit masters on save — so steps 3-5
above (manually pre-creating the Brand entry, UOM list, and Item Category
tree before the product upload) are no longer required prerequisites, just
optional pre-work. **`sakal/docs/Tenant/Shanju_Onboarding_Runbook.md` is
the current, up-to-date step list** — follow that file, not the numbered
steps above, for the actual onboarding sequence.

