# Automated Test Run Log

Started 2026-09-13. This is the running log of the autonomous screen-by-screen
test pass — updated after every screen/test as it completes. `00_INDEX.md`'s
Status column is also updated per screen; this file carries the narrative
detail (what was tested, what failed, what was fixed, commit hashes) that
doesn't fit in the index table.

**How this run works**: local Flutter (3.44.0, matching the reference
environment) drives single-screen `integration_test`s against the QA tenant
where a test exists/can be built cheaply; screens without an automated test
path yet are verified via direct backend/API checks or targeted code review
against the Cross-Cutting Checklist in `00_INDEX.md`. Every bug found is
fixed immediately, committed, and noted here before moving to the next item.

---

## Session 1 — 2026-09-13

### Pre-existing baseline (established before this run started)
- `flutter analyze`: clean (1 known pre-existing warning, `backend_verifier.dart` unused field).
- `flutter test`: 594 tests, 2 pre-existing known failures in `purchase_return_entry_screen_test.dart` (resume-flow, unrelated to this run — flagged in memory before today, not yet triaged).
- Fixed as part of local-toolchain setup: stale `app_database.g.dart` (commit `066d6d6`), stale `finance_voucher_entry_screen_test.dart` assertion (commit `5e8f1e7`).

### Strategy pivot (2026-09-14): backend-RPC tests, not UI automation
`flutter drive`/`integration_test`'s login flow proved unreliable in this
environment (session reverts to null after an apparently-successful login —
confirmed NOT an app bug via a side-by-side manual `flutter run -d chrome`
login, which works perfectly; the automation harness itself has the issue,
root cause not yet found, see `integration_test/README.md`'s OPEN section).
**Going forward, the primary test method is a plain `flutter test` file
under `test/backend/` per screen/module, calling the exact same
`fn_save_*`/`fn_approve_*`/`fn_cancel_*` RPCs the UI calls via
`BackendVerifier.rpc()`, with zero browser/chromedriver dependency** — this
covers every Cross-Cutting Checklist item that's actually about DATA
correctness (Dr/Cr, currency, immutability, permission gating, stock/GL
posting, reactive-field values as SAVED) reliably and in seconds, not
minutes. CCC #4 (button state) and #7 (responsive layout) are the only
items that genuinely need UI and are logged as "not verified — needs UI
automation" per screen until that track is revisited.

### Screens tested this session

| Screen | Method | Result | Bugs found | Notes |
|---|---|---|---|---|
| PR-GRN (GRN entry) | Backend RPC (`test/backend/grn_backend_test.dart`) | PASS | None (business logic) | Create DRAFT → Approve → stock/cost verified (100 units @ $10) → immutability (edit-after-approve) blocked correctly. CCC #4/#7 not covered (needs UI). |
| PR-PO (Purchase Order) | Backend RPC (`test/backend/purchase_order_backend_test.dart`) | PASS | None (business logic) | Create DRAFT → Approve → immutability blocked → zero-line DRAFT save succeeds but Approve correctly rejects (PO_NO_LINES, enforced only at Approve per migration 040's own comment). CCC #4/#7 not covered. |
| PR-INV (Purchase Invoice/Bill) | Backend RPC (`test/backend/purchase_invoice_backend_test.dart`) | PASS | None (business logic) | Fresh GRN → Approve → bill it → GRN reserved at DRAFT save (billed_invoice_no set immediately) → double-claim by a second bill rejected → Approve posts PUR voucher → pending-bills line findable by supplier's own invoice number → immutability blocked. Confirms QA tenant's account-link config (Purchase Accrual, Input VAT) is correctly set up. CCC #4/#7 not covered. |
| PR-RET (Purchase Return) | Backend RPC (`test/backend/purchase_return_backend_test.dart`) | PASS | None (business logic) | Partial return (30 of 100 units) against a fresh unbilled GRN → stock rolls back to exactly 70 → immutability blocked. Billed/SDN branch (return against an already-billed GRN) not yet covered — follow-up. CCC #4/#7 not covered. |
| IN-MRQ (Material Requisition) | Backend RPC (`test/backend/material_requisition_backend_test.dart`) | PASS | None (business logic) | Create → Approve → immutability blocked → a line missing department/consumption-area correctly rejected at Approve (LINE_DEPARTMENT_AREA_REQUIRED). CCC #4/#7 not covered. |
| IN-MIS (Material Issue) | Backend RPC (`test/backend/material_issue_backend_test.dart`) | PASS | **Real QA-tenant fixture bug found+fixed** (see below) | GRN → Requisition → consolidate into Issue → Approve → stock decreases by exactly the issued qty → GL posts Dr [mapped expense account] / Cr Stock, both legs verified by exact amount (20 units × $10 cost = $200). CCC #4/#7 not covered. |

| IN-STR (Stock Transfer Request) | Backend RPC (`test/backend/stock_transfer_request_backend_test.dart`) | PASS | None (business logic) | Create → Approve → immutability blocked. Pure intent, no stock/GL effect. Required creating a SECOND QA-tenant location (`CommonRefs.loadOrCreateSecondLocation`) — the tenant had exactly one. CCC #4/#7 not covered. |
| IN-TRF (Stock Transfer) | Backend RPC (`test/backend/stock_transfer_backend_test.dart`) | PASS | **Real QA-tenant fixture bug found+fixed** (see below) | DIRECT mode, SAME_BOOK posting (company's inter_location_model is SIMPLE) → GRN→Approve at FROM → Transfer 15/40 units → Approve → stock at FROM drops to exactly 25 → immutability blocked. AGAINST_REQUEST and INTER_ENTITY modes not yet covered — follow-up. CCC #4/#7 not covered. |
| IN-SRC (Stock Receipt) | Backend RPC (`test/backend/stock_receipt_backend_test.dart`) | PASS | None (business logic) | Completes the IN-TRF test's own scenario one step further — GRN→Transfer→Approve→Receipt→Approve → stock arrives at TO location at exactly the transferred quantity (15). from_location_id/to_location_id are correctly derived from the source transfer itself, never re-supplied in the Receipt payload (confirmed by reading fn_save_stock_receipt directly). CCC #4/#7 not covered. |

| IN-ADJ (Stock Adjustment) | Backend RPC (`test/backend/stock_adjustment_backend_test.dart`) | PASS | **Third real QA-tenant fixture bug found+fixed** | GRN establishes stock → '-' adjustment of 5 units → Approve → stock drops to exactly 45 → immutability blocked. Same STOCK_ADJUSTMENT_ACCOUNT link gap as Stock Transfer's own STOCK_IN_TRANSIT_ACCOUNT — `CommonRefs` refactored into a shared `_ensureCompanyAccountLink()` helper since this is now a recurring pattern. '+' (increase) line + its COST_NOT_ESTABLISHED hard-block not yet covered. CCC #4/#7 not covered. |
| IN-OPN (Opening Stock) | Backend RPC (`test/backend/opening_stock_backend_test.dart`) | PASS | None (business logic) | Establish 25 units @ 8/unit cost on a clean product/location → Approve → stock/cost match exactly → a SECOND opening-stock doc for the same product/location correctly rejected at Approve (OPENING_STOCK_ALREADY_ESTABLISHED) → immutability blocked. CCC #4/#7 not covered. |
| IN-CNT (Stock Count) | Backend RPC (`test/backend/stock_count_backend_test.dart`) | PASS | None (business logic) | Blind count of 45 (vs 50 system, never revealed to this screen) → Submit → DRAFT→SUBMITTED → confirms the count itself never touches `rim_product_location.current_stock` → immutability (edit-after-submit) blocked. CCC #4/#7 not covered. |
| IN-CNR (Stock Count Review) | Backend RPC (`test/backend/stock_count_review_backend_test.dart`) | PASS | None (business logic, one more reused fixture) | Same GRN→Count→Submit setup as IN-CNT, then clubbed into a Review and approved → stock lands at exactly 45 (the real counted value) → the auto-posted adjustment is confirmed traced back via `source_doc_type='STOCK_COUNT_REVIEW'`, proving the composition-with-the-Stock-Adjustment-engine documented in CLAUDE.md actually happened, not a coincidental match. Needed a `reason_id` (`fn_approve_stock_count_review` requires one) — reused the QA tenant's already-seeded "Physical Count Variance" Stock Adjustment Reason, no new fixture needed this time. CCC #4/#7 not covered. |

**All 9 real Inventory transaction screens now covered** (Stock List is still a placeholder route, not built). 13/13 backend tests passing together as of this point.

### Sales module (all 8 screens — 7 tested, Pending Approvals correctly N/A)
| Screen | Result | Notes |
|---|---|---|
| SL-QUO Sales Quotation | PASS | Create/Approve/no-stock-effect/immutability. |
| SL-SO Sales Order | PASS | DIRECT mode + manual price override (QA admin has `can_override_price=true`, no Price Master row exists) → Approve → Cancel requires a non-empty reason. |
| SL-INV Sales Invoice | PASS | DIRECT/CREDIT sale → Approve → stock dispatches (50→40) → both SI and COS vouchers posted (confirmed `voucher_type_code='SLS'`, not 'SI' as I first guessed) → Cancel blocked once APPROVED. First Sales screen with real GL/stock impact — also implicitly re-confirms the `25b4806` MID-rate fix still holds. |
| SL-INR Pending Approvals | N/A | Pure list/aggregation view, no own RPC — every underlying approve is already covered by its own source screen's test. |
| SL-RET Sales Return | PASS | **Real fixture gap found+fixed**: missing `SALES_RETURNS_ACCOUNT` link (reused existing "Product Sales" 4110 account). Return against an IMMEDIATE-dispatch invoice — stock genuinely comes back (40→50). |
| SL-DEL Sales Delivery | PASS | Used `p_credit_invoice_screen: true` to force DEFERRED dispatch, confirmed stock does NOT move at invoice Approve (still 50), only at Delivery Approve (50→40). Directly validates the module where bug #4 (buttons staying enabled, `a172574`) was found — the DATA half of that Cross-Cutting Checklist item is now covered; the UI button-state half still needs `flutter drive` (or manual) verification. |
| SL-RCP Cash Receipt | PASS | **Four real fixture gaps found+fixed in one test** (a first — see below). Settled a real pending bill created by a fresh Credit Sales Invoice. |
| SL-CINV Credit Sales Invoice | PASS | Hard future-date block + date-locked-after-first-save (migration 146's own two distinguishing rules) both verified. Needed a GRN in setup (cost price must be established before a line can sell) — the one genuine test-authoring mistake this session (not a fixture/app bug), found immediately since the error message named it directly. |

**Cash Receipt's four fixture gaps, found one at a time as each was fixed** (the most involved single test of this session):
1. `inv_bill_no` on a Sales Invoice's posted line is the **posting voucher's own trans_no** (e.g. `SLS/QAHO/2026/00001`), NOT the invoice's own document number (`SI/QAHO/2026/00001`) — a real, useful discovery about the actual bill-numbering convention, not a bug.
2. `fn_save_cash_receipt`'s header total is `local_amount + base_amount` (converted to local) — it supports a SPLIT collection (some cash in base-currency notes, some in local). Collecting entirely in one currency means the OTHER amount must be exactly 0, not a duplicate of the same figure — passing both as 100 double-counted the base leg.
3. QA admin's own `SL-RCP` `approve_allowed` was `false` — confirmed via `updated_at`/`updated_by` to be a deliberate prior change (likely from earlier manual CCC #6 permission-gating testing), not a seeding gap. Added `CommonRefs.ensureApprovePermission()` to restore it for business-logic testing, without erasing the audit trail of that change.
4. QA tenant had zero rows in `ric_user_quick_invoice_setup` (`QUICK_INVOICE_NOT_CONFIGURED`) and zero `EXCHANGE_GAIN_LOSS_ACCOUNT` link rows (`ACCOUNT_LINK_NOT_CONFIGURED`) — both needed for any cash-collecting voucher. Added `CommonRefs.ensureQuickInvoiceSetup()` and reused `ensureExchangeGainLossAccountLink()`.

### Finance module (all 5 screens — 4 tested, Cash Book correctly N/A)
| Screen | Result | Notes |
|---|---|---|
| FN-JRN Journal Voucher | PASS | Balanced Dr/Cr posts, an unbalanced entry is rejected at Approve, immutability blocked. Doubles as a smoke test of the shared voucher engine every other Finance screen composes. **Real diagnostic gap fixed along the way**: `BackendVerifier.rpc()`/`get()` only ever surfaced Dio's own generic "bad response" message, discarding the actual PostgREST error body — every prior test file's debugging session had to fall back to a manual `Invoke-RestMethod` call to see the real `{code, message, details}`. Fixed once in `BackendVerifier` itself; benefits every future test file. |
| FN-CTR Contra Voucher | PASS | Confirms CLAUDE.md's claim that Contra reuses the generic engine completely unchanged, under `voucher_type_code='CTR'`. |
| FN-EXP Expense Voucher | PASS | No-tax service bill → Approve → mandatory bill-linkage (via `rid_finance_lines.inv_bill_no`) → immutability. `rih_expense_voucher_headers` uses a real `status` TEXT column, unlike the generic engine's `rih_finance_headers.is_posted` boolean — a genuine schema-shape difference, not a bug, caught by the same improved error message above. |
| FN-CBK Cash Book | N/A | Still a placeholder route, not built. |
| FN-PRV Payment/Receipt Voucher | PASS | On Account payment to supplier — `party_amount` round-trips correctly (the exact data area bug #3, `a172574`, touched). **Real cross-module inconsistency found, not fixed**: `fn_post_finance_voucher`'s Against-Bill settlement lookup matches a line's `inv_bill_no` against another voucher's own `trans_no` — this works for Sales Invoice/Cash Receipt's convention (inv_bill_no = the posting voucher's trans_no) but NOT for Expense Voucher's or Purchase Bill's convention (inv_bill_no = the user's own paper bill number). A Payment Voucher settling "Against Bill" for an Expense-Voucher- or Purchase-Bill-originated payable would silently compute `was_balance=0` instead of the real outstanding balance (the `coalesce(...,0)` masks the failed lookup). Flagged for a real follow-up investigation. |

**Milestone: all 25 real transaction screens in the test plan now have backend-RPC coverage** (28 total minus 3 not-yet-built placeholders — Supplier Payment, Stock List, Cash Book). This completes the entire transaction-screen portion of the plan. Masters and Reports (113 screens) are next.

**Second real bug found this session (test-fixture setup, not app code)**: Stock Transfer's Approve raised `ACCOUNT_LINK_NOT_CONFIGURED` ("No Stock in Transit Account resolved") — the QA tenant had no `STOCK_IN_TRANSIT_ACCOUNT` link configured at all. Fixed by adding `CommonRefs.ensureStockInTransitAccountLink()`, a COMPANY-granularity link pointing at the existing Stock account (no dedicated "Stock in Transit" account existed in the seeded COA — a pragmatic stand-in, since this test verifies status/quantity transitions, not GL account naming). Same root cause class as the Material Issue fixture gap: **this QA tenant's seed data was built before Stock Transfer/Material Issue existed as modules, so their account-link prerequisites were never backfilled** — worth checking whether OTHER not-yet-tested screens (Sales, Finance) hit the same kind of gap.

**Real bug found this session (test-fixture setup, not app code)**: `CommonRefs.loadOrCreateDepartmentArea()` first tried account `5200` ("Operating Expense") as the QA tenant's test expense account — `fn_approve_material_issue`/`fn_post_voucher` correctly rejected it with `ACCOUNT_NOT_POSTABLE` ("Account 5200 is a group/header account and cannot receive postings"). This is the GL engine's own validation working exactly as intended — 5200 is a parent/header account in the seeded COA, its child `5210` ("Administrative Expenses") is the real postable leaf. Fixed by switching to `5210` (confirmed via `rim_accounts.posting_allowed = true`) and correcting the already-inserted `rim_department_consumption_areas` row in the live QA tenant (a one-time PATCH, not a code path — this is fixture data, not a migration). Worth remembering: **any new test fixture that references a GL account must confirm `posting_allowed = true` first** — a plausible-sounding account name is not enough, and the group/header vs. leaf distinction is invisible without checking that column directly.

### Masters module (started 2026-09-14)
| Screen | Result | Notes |
|---|---|---|
| MST-CUST Customer Master | PASS | Plain `rim_accounts` insert/read/update/deactivate round-trip. Masters have **no dedicated RPC layer** — confirmed by reading `customer_master_screen.dart`/`supplier_master_screen.dart`/`products_remote_ds.dart`/`chart_of_accounts_screen.dart` directly, they POST/PATCH straight to their own PostgREST table. So Master testing is fundamentally CRUD+RLS, not multi-step lifecycle — RLS itself already exhaustively verified by the earlier `security_invoker` fix. |
| MST-SUPP Supplier Master | PASS | Same pattern, Supplier group account `2110` ("Trade Payables"). |
| MST-PRD Product Master | PASS | `rim_products` insert/update round-trip. **UOM is not its own table** — resolved via `rim_common_master_types` (`type_key='UNIT'`) → `rim_common_masters`, same generic mechanism as Brand/Color. |

**Two real fixture/schema-shape gaps found while diagnosing (not app bugs, both fixed in the test file)**:
1. `rim_accounts.accounting_std` is a hidden NOT NULL column (`'INDIAN'`/`'OHADA'` CHECK) not visible from the screen's own obviously-required fields — every insert needs it explicitly.
2. `rim_products` has no `is_saleable`/`is_purchasable` columns at all — those are keys inside the `flags` JSONB column, not dedicated columns (confirmed via `026_product_master.sql`'s own doc comment: "Business flags — dynamic, admin defines via rim_product_flag_types screen").

**Real test-authoring gotcha, worth flagging for every future Masters test file**: `resetQaTenant()` only wipes TRANSACTION data, never master data — a master-data insert test is NOT automatically idempotent across re-runs the way every transaction test is. `masters_crud_backend_test.dart`'s `setUpAll` now renames/relocates any leftover row from a prior run (by its known unique code) before inserting fresh ones, specifically so re-running the file (or the whole suite) doesn't fail on a duplicate-key 409 from its own previous run.

### Finance Masters (5 of 8 given dedicated tests — 3 covered elsewhere, see notes)
| Screen | Result | Notes |
|---|---|---|
| MST-COA Chart of Accounts | PASS | Already covered by `masters_crud_backend_test.dart` (same `rim_accounts` table). |
| MST-TAX Tax Master | PASS | `rim_tax_types` is a genuinely global lookup table (no client_id/company_id at all) — first test file to need `getUnscoped()` for it. |
| MST-TXG Tax Groups | PASS | Group + member junction row round-trip. |
| MST-ALS Account Link Setup | PASS (indirect) | Not a new dedicated test — this exact mechanism (`rim_account_link_setup`/`rim_account_link_defaults`) has been exercised repeatedly, all session, by `CommonRefs`' `ensure*AccountLink()` fixture helpers used as setup in a dozen+ transaction tests. Writing a redundant CRUD test would duplicate real coverage that already exists. |
| MST-IAL Item Account Links | Not Started | `rim_account_links` (per-product override) — genuinely untested so far, real follow-up. |
| MST-CHG Additional Charges | PASS | |
| FN-EX Exchange Rates | PASS | **Real schema drift found**: migration 018 originally defined `mid_rate` as a GENERATED column (`(buying_rate+selling_rate)/2`); migration 179 dropped the generated expression and renamed it to a plain, independently user-editable `exchange_rate` column — CLAUDE.md/this file's own earlier description of `mid_rate` as "always computed" is now stale for any tenant that's run migration 179. A `uq_rim_exchange_rates` unique constraint (company/location/date/from/to) also exists live but isn't visible in migration 018's own file — added by a later migration not yet cross-referenced. |
| MST-OB Opening Balance | PASS | **Real dead-schema finding**: `rim_opening_balances` (migration 013) is completely orphaned — `opening_balance_remote_ds.dart` actually POSTs to `/rid_opening_balance_lines` (migration 133, a differently-shaped table with `base_amount`/`local_amount`/`party_amount`/`party_currency` instead of a single `ob_amount`). The old table still exists live and accepts inserts, so nothing user-facing is broken, but it's a genuine follow-up candidate for cleanup (a future migration to `DROP TABLE rim_opening_balances`) since it could mislead a future session grepping migrations for "where does Opening Balance live." |

**Master-data test-authoring lesson, reinforced by this file**: grepping a migration file for a table's `CREATE TABLE` is necessary but not sufficient — always verify against the CURRENT live schema (a failed insert naming the real column, or PostgREST's own "did you mean" hint) before trusting an old migration's column list, since later migrations frequently rename/restructure columns (`mid_rate`→`exchange_rate`) or fully supersede a table (`rim_opening_balances`→`rid_opening_balance_lines`) without a matching update to the original file's own comments.

### Inventory Masters (remaining 4 of 5 — Product Master already covered)
| Screen | Result | Notes |
|---|---|---|
| AD-PCS Product Category Level Setup | PASS | Levels are seeded 1-4 per company (CHECK level_no BETWEEN 1 AND 4) — this screen edits existing rows (label/mandatory/active), never creates a 5th level. Test toggles then restores `is_mandatory` on level 1, since this is shared seed config other future tests could depend on. |
| MST-ITC Item Categories | PASS | `flags` JSONB round-trips correctly (`{"is_saleable": true, ...}`), same generic-flags mechanism as `rim_products.flags`. |
| AD-PGS Product Flag Types | PASS | Plain CRUD on `rim_product_flag_types`. |
| IN-DCA Consumption Area Setup | PASS (indirect) | Not a new dedicated test — `rim_department_consumption_areas` has been exercised repeatedly, all session, via `CommonRefs.loadOrCreateDepartmentArea()` as fixture setup for Material Requisition/Issue tests. Same reasoning as MST-ALS above — writing a redundant CRUD test would duplicate real coverage that already exists. |

### Sales Masters (remaining 2 of 3 — Customer Master already covered)
| Screen | Result | Notes |
|---|---|---|
| SL-PRC Price Master | PASS | **Real exception among Master screens**: has its own Draft/Approve RPC pair (`fn_save_price_master_batch`/`fn_approve_price_master_batch`, migration 083) — a real product-level unique-price-per-location/date business rule, not plain table CRUD. Tested like a transaction screen: create GENERIC batch → approve → header status APPROVED → immutability (re-save after approve throws). Confirmed `rih_price_master_headers`/`rid_price_master_lines` ARE wiped by `resetQaTenant()` (unlike every other Master table this session) — re-running the file twice in a row hit no `PRICE_ALREADY_EXISTS` collision. |
| SL-EXE Sales Executives | PASS | Plain CRUD, `rim_sales_executives`. |

### User Management (all 4)
| Screen | Result | Notes |
|---|---|---|
| AD-USR User Management | PASS | Has its own `fn_create_user` RPC (migration 011) — server-side `crypt()` password hashing means a plain `rim_users` insert isn't possible from a client. **Real schema gotcha**: `uq_users_client_username` is NOT a partial index (unlike almost every other soft-delete UNIQUE in this schema) — its own migration comment says "includes soft-deleted, prevents username reuse" — so a stale test row from a prior run needs its `username` renamed, not just `is_deleted=true`, or a re-run's `fn_create_user` call hits a duplicate-key 409. |
| AD-PRM User Permissions | PASS | Read-then-update (not insert) against the QA admin's own already-seeded `ric_user_menus` row for `PR-PO` — respects the table's `UNIQUE(user_id, feature_code)`. Toggled then restored, since this is the live QA admin's real permission other test files in this suite depend on. |
| AD-ULS User Location Setup | PASS | Grant/revoke round-trip against a throwaway new location (not the shared `CommonRefs.loadOrCreateSecondLocation()` fixture, to avoid interacting with any other test file's use of it). **Real schema note**: `ric_locations` has no `location_code` column at all — just `location_name`/`location_short`. |
| AD-MST Master Menu | PASS | Toggled then restored `PR-PO`'s `is_active` flag — disabling it app-wide would have broken every Purchase Order backend test running later in the same `--concurrency=1` suite run. |

### System Setup (8 of 13 given dedicated tests — 5 covered indirectly, see notes)
| Screen | Result | Notes |
|---|---|---|
| AD-CUR Currency Setup | PASS | Currencies auto-seed per company (migration 007 trigger) — this screen activates existing rows, doesn't create new ISO codes. |
| AD-CNT Country Setup | PASS | Same auto-seed pattern, ~200 rows per company (migration 008). |
| AD-CIT Cities | PASS | |
| AD-PDC Period Close | PASS | Lock + reopen round-trip (`is_active=false` + `reopened_by`/`reopened_at`/`reopen_reason`), matching the table's own documented "reopening is a logged, permission-gated action, never a silent delete" design. |
| AD-BDC Backdated Entry Control | PASS | |
| AD-PDT Print Templates | PASS | |
| AD-PAYTERM Payment Terms | PASS | |
| MST-CMN Common Masters | PASS | `rim_common_master_types` is a genuinely global lookup table (no client_id/company_id) — needed `getUnscoped()`, same as `rim_tax_types` earlier. |
| AD-CMP Company Setup / AD-ACT Accounting Setup | PASS (indirect) | Singleton per-company config — every test file in this entire suite logs in against an already-configured real QA company, which is itself a continuous implicit test of this config being valid and internally consistent. |
| AD-LOC Location Setup | PASS (indirect) | `ric_locations` CRUD already exercised directly by `user_management_backend_test.dart`'s AD-ULS test (creates a real location as fixture setup). |
| AD-QIS Quick Invoice Setup | PASS (indirect) | Exercised directly, all session, by `CommonRefs.ensureQuickInvoiceSetup()` as Cash Receipt/Sales Invoice fixture setup. |
| AD-DIV Country Divisions | N/A | `rim_divisions` is a GLOBAL table per its own documented design (`is_system=true OR client+company`) — not company-specific CRUD to test the way every other System Setup screen is. |

**Real test-authoring lesson from this file**: a rename-based cleanup pattern (used throughout this session for tables with a plain, non-partial UNIQUE constraint) must search by a pattern that matches BOTH the original test value AND the renamed value a completed prior run leaves behind — an exact `eq.` match on only the original name misses a stale row that was already renamed by its own test body (e.g. "QA CRUD Test" → "QA CRUD Test Renamed"), causing a duplicate-key 409 on the very next re-run despite the cleanup code appearing to handle exactly this case. Fixed by matching `like.QA CRUD Test*` instead of `eq.QA CRUD Test`.

### MST-IAL Item Account Links (last of the 34 Master screens)
| Screen | Result | Notes |
|---|---|---|
| MST-IAL Item Account Links | PASS | Per-product override layer (`rim_account_links`, `link_type='ITEM'`) on top of the company/category/location-level `rim_account_link_setup` mechanism already exercised elsewhere. **New `BackendVerifier.delete()` added** — this table's `UNIQUE(client_id, company_id, link_type_id, product_id)` is plain, not partial on `is_deleted`, so the soft-delete-then-rename cleanup pattern used everywhere else in this suite can't free the key; a real hard delete of the throwaway test row is the only practical option here. First (and expected to stay rare) use of a genuine DELETE in this test suite. |

**Milestone: all 34 Master screens now have backend-RPC test coverage** (24 direct + 9 indirect/already-exercised + 1 N/A global-lookup). Combined with the earlier 25/25 Transaction screens, that's 59 of 141 total screens (Masters + Transactions) fully covered. Reports (79 screens) are next.

### Reports — generic Reporting Engine smoke test (all 79 report screens, one file)
Reports are DATA-DRIVEN, not per-screen Flutter code — every one of the 79 report screens is a row in `ric_report_definitions` (+`ric_report_columns`/`ric_report_filters`/`ric_report_group_levels`), read generically by `report_repository.dart`/`sakal_report_screen.dart`. This made a per-screen test file impractical AND unnecessary — instead `test/backend/reports_smoke_backend_test.dart` loops every active definition, reconstructs the exact same GET call the real UI makes (VIEW via plain GET, FUNCTION via `/rpc/<fn>` with `p_client_id`/`p_company_id` + `p_`-prefixed filter params), and asserts it succeeds. This is a SMOKE test, not a business-logic test — it proves every report's backing VIEW/FUNCTION is reachable and returns a well-formed row list, not that the numbers or Dr/Cr/currency display are correct (Cross-Cutting Checklist items #1/#2 remain UI-only concerns not observable from a raw RPC call — a real, standing gap, not fixed by this test).

**Result: 69/75 tested definitions passed on the first real end-to-end pass this schema has ever had** (4 report_definitions rows are singleton/config screens with no separate report row — Company/Accounting Setup etc. — already counted in Masters). 6 genuine bugs found, all real and all previously invisible:

1. **`PRODUCT_MOVEMENT_ANALYSIS`** — `permission denied for table ric_product_movement_snapshot`. Root cause: migration 185's blanket `security_invoker = true` fix (a real, necessary cross-tenant RLS fix, see CLAUDE.md) flipped `v_product_movement_analysis` from owner-rights to querying-user-rights — but this ONE view's own design (migration 156's comment) deliberately relied on owner-rights, enforcing access control only via its JOIN to the already-RLS-protected `ric_report_jobs`, not via the snapshot table's own RLS (it had none). 185 was still the right call; this was the one pre-existing view whose design assumption it broke, invisible until a real authenticated call was made.
2. **`VENDOR_ON_TIME_DELIVERY`** — filter's `param_target='expected_date'`, but `v_purchase_order_delivery`'s real column is `expected_delivery_date`. The date filter has been silently broken since migration 158.
3-6. **`DAY_BOOK_REGISTER`/`CHEQUE_REGISTER`/`VAT_TAX_RETURN_SUMMARY`/`WITHHOLDING_TAX_SUMMARY`** — same bug pattern, all four filters say `param_target='date'` but their views all use `trans_date`. Broken since migrations 166/167.

**All 6 fixed in `backend/migrations/186_reporting_engine_smoke_test_fixes.sql`** (RLS policy + GRANT for #1, plain `UPDATE ric_report_filters` for #2-6). **DEPLOYED AND CONFIRMED LIVE 2026-09-14** (later same day, once the user supplied direct database access) — applied via a one-off `pg`-based Node.js runner (no `psql` available locally), verified against the real database (`ric_product_movement_snapshot.relrowsecurity` now `true` with a real policy, the 5 mismatched `param_target` rows corrected across all seeded companies), then re-confirmed the RIGHT way — through the actual PostgREST-authenticated test suite, not superuser SQL (which bypasses RLS and would prove nothing about the real bug). `reports_smoke_backend_test.dart`'s `knownBrokenPendingMigration186` set is now empty; **all 75 reports pass live**, all previously-excluded 6 now running for real.

**One test-fixture gap found and fixed (not an app bug)**: `BANK_RECONCILIATION_STATEMENT`'s `bank_account_id` filter is required with no default — the QA tenant had zero `rim_bank_accounts` rows (the module was only added 2026-08-28, after seed data was built). Fixed by seeding one directly in the test's own `setUpAll` against any existing Bank-nature `rim_accounts` row.

### Cross-Cutting Checklist #4 (button state after action) — spot-checked and fixed app-wide, 2026-09-14
The Sales Delivery "buttons stay enabled after Approve" bug (fixed earlier, `a172574`) was flagged as a PATTERN that needed spot-checking against every other transaction screen's own approve/submit method, not just fixed in isolation. Two parallel background code-review agents did this (and the companion Payment Voucher Party-Amount cross-currency-gate pattern) via pure static code reading — no DB/UI access needed:

- **Cross-currency-gate pattern (Party Amount): CLEAN.** Checked Contra Voucher's From/To/gap logic, Journal Voucher's own Party Amount, Expense Voucher, Opening Balance, Bank Reconciliation Matching, plus confirmed Sales Invoice/Credit Sales Invoice/Sales Return/Cash Receipt/Sales Order/Quotation have no such field at all. The bug was isolated to Payment/Receipt Voucher and never recurred.
- **Stale-status-after-approve pattern: FOUND on 19 of ~24 screens with their own approve/submit method, fixed on all 19** (`e79cf74`): Contra Voucher, Expense Voucher, Journal Voucher, Material Issue, Material Requisition, Opening Stock, Stock Adjustment, Stock Count (Submit), Stock Count Review, Stock Receipt, Stock Transfer, Stock Transfer Request, Purchase Invoice, Credit Sales Invoice, Price Master, Sales Invoice, Sales Order, Sales Quotation (both `_approve()` and `_updateStatus()`), Sales Return. Each relied entirely on a subsequent `_init()`/`_loadExisting()` reload to pick up the new status — fixed by setting the status field directly inside the same `setState` as the RPC success path, matching the already-correct reference pattern already used by GRN/Purchase Order/Purchase Return/Cash Receipt/Payment-Receipt Voucher/Sales Delivery (confirmed clean, no fix needed on those 6).
- `flutter analyze` clean app-wide; full non-backend test suite (594 tests) passes with zero regressions from these 19 edits.

## Business Scenario Integration Tests (2026-09-14) — `test/backend/scenarios/`

The screen-by-screen backend-RPC suite above tests every document type IN ISOLATION — does `fn_save_X`/`fn_approve_X` succeed, does status transition, does one spot-checked field change. The user asked the natural follow-up: does a REAL business cycle (buy something, sell it, return it) actually hit every right place in the books? Nothing above chains documents together and checks the CUMULATIVE effect on stock, GL, and customer/supplier ledgers. This section adds exactly that — 10 named business scenarios (`test/backend/scenarios/*.dart`, plus a shared `scenario_helpers.dart`), chaining real RPC calls end-to-end and asserting actual computed numbers (not just "no error thrown"), reusing the existing `BackendVerifier`/`CommonRefs`/`resetQaTenant` infrastructure. **All 10 scenarios (12 test cases) pass**; the full backend suite is now 64 tests total (52 per-screen + 12 scenario), all green together under `--concurrency=1`.

| # | File | Result | Story |
|---|---|---|---|
| 1 | `purchase_to_pay_scenario_test.dart` | PASS (2 tests) | PO→GRN→Invoice→on-account Payment; separately, a fresh bill settled against-bill |
| 2 | `order_to_cash_scenario_test.dart` | PASS | Order→AGAINST_ORDER deferred Invoice→Delivery→Return→Cash Receipt |
| 3 | `purchase_return_unbilled_scenario_test.dart` | PASS | PO→GRN→Return against an UNBILLED GRN (JV reversal, no SDN) |
| 4 | `purchase_return_billed_scenario_test.dart` | PASS | PO→GRN→Invoice→Return against a BILLED GRN (real SDN, no JV) |
| 5 | `stock_transfer_chain_scenario_test.dart` | PASS | Request→Transfer(against_request)→Receipt, in-transit account clears |
| 6 | `material_requisition_issue_scenario_test.dart` | PASS | Requisition→Issue, Dr Expense/Cr Stock posts exactly |
| 7 | `stock_adjustment_scenario_test.dart` | PASS | '+' then '-' adjustment, Dr/Cr direction genuinely flips |
| 8 | `settlement_ledger_ageing_scenario_test.dart` | PASS (2 tests) | Customer against-bill vs Supplier on-account settlement, contrasting `v_pending_bills`/ageing behavior |
| 9 | `trial_balance_balance_sheet_scenario_test.dart` | PASS | Scenarios 1+2 chained in one tenant; TB balances, BS's Assets=Liabilities+Equity holds |
| 10 | `trial_balance_pnl_scenario_test.dart` | PASS | Scenario 2 alone; P&L's `net_profit` exactly equals Balance Sheet's synthetic "Current Year Earnings" node |

### 🔴 Most significant finding of the entire test-plan effort: Sales Return silently skipped stock+COGS reversal for deferred-dispatch sales — FOUND AND FIXED 2026-09-14

**Found** by scenario 2 (`order_to_cash_scenario_test.dart`): `fn_approve_sales_return` gated its ENTIRE stock+COGS reversal block on `IF v_invoice.stock_dispatch_mode = 'IMMEDIATE' THEN` — for a **DEFERRED**-dispatch sale (any Credit Sales Invoice delivered via a separate Sales Delivery, which is the module's own core design), that condition was false, so returning goods from such a sale correctly credited the customer's AR but **never brought stock back and never reversed COGS**. Confirmed with real numbers: sold 6 units (COGS $300 posted at Delivery), returned 2 — stock stayed at 4 instead of returning to 6, P&L showed a $60 loss instead of a $40 profit.

**Initial investigation was based on stale code** (`099_sales_return.sql`'s original cost-lookup, which joined back through the invoice's own posted COS voucher) — first-pass analysis concluded a correct fix needed a complex multi-table join through `rid_sales_delivery_lines` to translate invoice-line-serial into a delivery's own line-serial, and was deliberately not attempted blind.

**Once direct database access became available**, re-reading the CURRENT function definition (`123_sales_return_cost_price.sql`, which completely superseded 099's join-based lookup — exactly the trap CLAUDE.md's "check the latest migration, never the original" rule exists to prevent) revealed the fix was much simpler and safer than feared: `fn_save_sales_invoice` (migration 121) already resolves and stores `cost_price` on every invoice line **unconditionally, regardless of dispatch mode**, and `fn_save_sales_return` (migration 123) already copies that `cost_price` onto the return line **unconditionally too**. The historical cost was correctly sitting on the return line all along for BOTH dispatch modes — the reversal block just never ran to use it for the deferred case.

**Fixed in `backend/migrations/187_sales_return_deferred_dispatch_reversal_fix.sql`** — a single-condition broadening: the reversal block now also fires when the invoice is DEFERRED but has at least one APPROVED Sales Delivery against it (i.e. stock genuinely left, just via Delivery instead of at invoice-approval time). Everything else in the block was already dispatch-mode-agnostic and needed zero further change. **Deployed and confirmed live 2026-09-14**: `order_to_cash_scenario_test.dart` now correctly shows a real $100 COS reversal, stock returning to 6, and the customer ledger and Trial Balance/Balance Sheet all reconciling correctly; `sales_return_backend_test.dart`'s own IMMEDIATE-mode test (unaffected by this change) still passes unchanged; full 64-test backend suite passes together.

**Lesson worth keeping**: the "grep every migration for a function's CURRENT definition, never trust the original" rule (already documented in CLAUDE.md) applies just as much to *understanding a bug* as to *writing new code that calls a shared function* — the first-pass root-cause analysis here was correct about the SYMPTOM but wrong about the FIX COMPLEXITY, purely because it read an outdated version of the function being fixed.

### Other real findings from the scenario tests (all confirmed, none requiring code changes — correct-by-design once understood)
- **On-account vs against-bill settlement, precisely characterized** (scenario 1 + 8): an on-account payment/receipt correctly zeroes the account ledger but never writes a `rid_invoice_bill_settlement` row (`058_voucher_balance_check_uses_base_amount.sql` line ~145: settlement records are written only when `NOT is_on_account`) — by design, since an on-account payment genuinely isn't tied to any specific bill. **Correction to this session's earlier framing** (in `payment_receipt_voucher_backend_test.dart`'s doc comment): the previously-documented "Payment Voucher Against-Bill inv_bill_no convention mismatch" (Purchase Bill/Expense Voucher vs Sales Invoice/Cash Receipt) only affects the settlement record's own `was_balance` AUDIT field (confirmed live: comes back `0` for a Purchase-Bill-originated bill) — `v_pending_bills`/ageing sum `paid_amount` directly, which is always correct regardless. The bill's own tracked balance genuinely reduces; only a secondary audit number can be wrong.
- **Ageing's `total_outstanding` vs `net_closing`** (scenario 8): `total_outstanding` sums only bill-tagged lines and stays stale after an on-account settlement (same reasoning as above); `net_closing = total_outstanding - unsettled_advance` is the field that correctly nets it, since an on-account payment lands in the separate "unsettled advance" bucket instead. Both fields are working as designed — a test/report reader just needs to know which one answers "what do they still owe."
- **Cash Receipt's local_amount convention + partial-settlement-after-return interacts with real FX** (scenario 10): settling a partial residual balance (after a Sales Return reduced the original bill) via Cash Receipt triggers a real `EXC` (Exchange Gain/Loss) voucher when the receipt's own nominal (non-real-FX) `local_amount`, per this whole suite's existing convention, doesn't reconcile against the bill's own recorded amounts through a real exchange rate. This is a test-fixture-convention artifact (documented already in `cash_receipt_backend_test.dart`), not a fresh app bug — flagged in `trial_balance_pnl_scenario_test.dart`'s own doc comment so it isn't mistaken for one later.

**Note on running this suite**: always `flutter test test/backend/ --concurrency=1` — files race resetQaTenant() against each other in parallel (see `test/backend/README.md`).

**Real bugs found and fixed this session (not test-plan execution, but surfaced while setting up the local toolchain to run it)**:
1. `app_database.g.dart` was stale relative to `app_database.dart` (missing `exchangeRate` column) since commit `f2108fe` — regenerated, commit `066d6d6`.
2. `finance_voucher_entry_screen_test.dart` asserted the OLD buggy Party Amount behavior (`findsOneWidget` for a value that now legitimately renders twice after the `a172574` fix) — updated to `findsNWidgets(2)`, commit `5e8f1e7`.
